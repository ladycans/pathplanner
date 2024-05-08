import 'dart:math';

import 'package:pathplanner/path/path_constraints.dart';
import 'package:pathplanner/path/path_point.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/trajectory/config.dart';
import 'package:pathplanner/util/geometry_util.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';
import 'package:pathplanner/util/wpimath/kinematics.dart';
import 'package:pathplanner/util/wpimath/math_util.dart';

class PathPlannerTrajectory {
  final List<TrajectoryState> states;

  PathPlannerTrajectory.fromStates(this.states);

  PathPlannerTrajectory({
    required PathPlannerPath path,
    required ChassisSpeeds startingSpeeds,
    required Rotation2d startingRotation,
    required RobotConfig robotConfig,
  }) : states = [] {
    int prevRotationTargetIdx = 0;
    Rotation2d prevRotationTargetRot = startingRotation;
    int nextRotationTargetIdx = _getNextRotationTargetIdx(path, 0);
    Rotation2d nextRotationTargetRot = Rotation2d.fromDegrees(
        path.pathPoints[nextRotationTargetIdx].rotationTarget!.rotationDegrees);

    int numModules = robotConfig.moduleLocations.length;

    for (int i = 0; i < path.pathPoints.length; i++) {
      PathPoint p = path.pathPoints[i];

      if (i > nextRotationTargetIdx) {
        prevRotationTargetIdx = nextRotationTargetIdx;
        prevRotationTargetRot = nextRotationTargetRot;
        nextRotationTargetIdx = _getNextRotationTargetIdx(path, i);
        nextRotationTargetRot = Rotation2d.fromDegrees(path
            .pathPoints[nextRotationTargetIdx].rotationTarget!.rotationDegrees);
      }

      // Holonomic rotation is interpolated
      double t = (i - prevRotationTargetIdx) /
          (nextRotationTargetIdx - prevRotationTargetIdx);
      Rotation2d holonomicRot =
          _cosineInterpolate(prevRotationTargetRot, nextRotationTargetRot, t);

      Pose2d robotPose =
          Pose2d(Translation2d(x: p.position.x, y: p.position.y), holonomicRot);
      states.add(TrajectoryState());
      states[i].pose = robotPose;
      states[i].moduleStates =
          List.generate(numModules, (index) => SwerveModuleTrajState());

      if (i != 0) {
        states[i].deltaPos = states[i]
            .pose
            .translation
            .getDistance(states[i - 1].pose.translation);
        states[i].deltaRot =
            states[i].pose.rotation - states[i - 1].pose.rotation;
      }

      for (int m = 0; m < numModules; m++) {
        Translation2d moduleFieldPos = robotPose.translation +
            robotConfig.moduleLocations[m].rotateBy(robotPose.rotation);

        states[i].moduleStates[m].fieldPos = moduleFieldPos;

        if (i != 0) {
          states[i].moduleStates[m].deltaPos = states[i]
              .moduleStates[m]
              .fieldPos
              .getDistance(states[i - 1].moduleStates[m].fieldPos);
        }
      }
    }

    // Pre-calculate the pivot distance of each module so that it is not
    // calculated for every traj state
    List<num> modulePivotDist = [];
    for (int m = 0; m < numModules; m++) {
      modulePivotDist.add(robotConfig.moduleLocations[m].getNorm());
    }

    // Calculate the headings at each state
    for (int i = 0; i < states.length; i++) {
      if (i != states.length - 1) {
        states[i].heading =
            (states[i + 1].pose.translation - states[i].pose.translation)
                .getAngle();

        for (int m = 0; m < numModules; m++) {
          states[i].moduleStates[m].fieldAngle =
              (states[i + 1].moduleStates[m].fieldPos -
                      states[i].moduleStates[m].fieldPos)
                  .getAngle();
          states[i].moduleStates[m].angle =
              states[i].moduleStates[m].fieldAngle - states[i].pose.rotation;
        }
      } else {
        states[i].heading = states[i - 1].heading;

        for (int m = 0; m < numModules; m++) {
          states[i].moduleStates[m].fieldAngle =
              states[i - 1].moduleStates[m].fieldAngle;
          states[i].moduleStates[m].angle =
              states[i].moduleStates[m].fieldAngle - states[i].pose.rotation;
        }
      }
    }

    // Set the initial module velocities
    List<SwerveModuleState> initialStates = robotConfig.kinematics
        .toSwerveModuleStates(ChassisSpeeds.fromFieldRelativeSpeeds(
            startingSpeeds, states[0].pose.rotation));
    for (int m = 0; m < numModules; m++) {
      states[0].moduleStates[m].speedMetersPerSecond =
          initialStates[m].speedMetersPerSecond;
    }
    states[0].timeSeconds = 0.0;
    states[0].fieldSpeeds = startingSpeeds;

    num frictionTorque = robotConfig.moduleConfig.driveMotorTorqueCurve.get(
        robotConfig.moduleConfig.maxDriveVelocityRPM); // TODO: air resistance?

    num moduleFrictionForce =
        robotConfig.moduleConfig.wheelCOF * (robotConfig.massKG * 9.8);

    for (int i = 1; i < states.length - 1; i++) {
      // Calculate the linear force vector and torque acting on the whole robot
      Translation2d linearForceVec = const Translation2d();
      num totalTorque = 0.0;
      for (int m = 0; m < numModules; m++) {
        num lastVel = states[i - 1].moduleStates[m].speedMetersPerSecond;
        // This pass will only be handling acceleration of the robot, meaning that the "torque"
        // acting on the module due to friction will be fighting the motor
        num availableTorque = robotConfig.moduleConfig.driveMotorTorqueCurve
                .get(lastVel / robotConfig.moduleConfig.rpmToMPS) -
            frictionTorque;
        num wheelTorque =
            availableTorque * robotConfig.moduleConfig.driveGearing;
        num forceAtCarpet =
            wheelTorque / robotConfig.moduleConfig.wheelRadiusMeters;
        Translation2d forceVec = Translation2d.fromAngle(
            forceAtCarpet, states[i - 1].moduleStates[m].fieldAngle);

        // Add the module force vector to the robot force vector
        linearForceVec += forceVec;

        // Calculate the torque this module will apply to the robot
        Rotation2d angleToModule = (states[i - 1].moduleStates[m].fieldPos -
                states[i - 1].pose.translation)
            .getAngle();
        Rotation2d theta = forceVec.getAngle() - angleToModule;
        totalTorque += forceAtCarpet * modulePivotDist[m] * theta.getSin();
      }

      // Convert the max forces experienced by the robot into linear and angular acceleration
      num linearAccel = linearForceVec.getNorm() / robotConfig.massKG;
      num angularAccel = totalTorque / robotConfig.moi;

      // Use the robot accelerations to calculate how each module should accelerate
      for (int m = 0; m < numModules; m++) {
        // First, we need to calculate the acceleration vector at the location of the module
        // This vector will be the robot's linear acceleration vector + the acceleration vector due
        // to angular accel at the location of the module
        Translation2d accelerationVector =
            Translation2d.fromAngle(linearAccel, linearForceVec.getAngle());

        Rotation2d angleToModule =
            (states[i].moduleStates[m].fieldPos - states[i].pose.translation)
                .getAngle();
        num angAccelMps = angularAccel * modulePivotDist[m];
        Translation2d angAccelVector = Translation2d.fromAngle(
            angAccelMps, angleToModule + Rotation2d.fromDegrees(90));

        accelerationVector += angAccelVector;

        // Now that we have the acceleration vector, we can calculate how much the actual module
        // will accelerate
        Rotation2d modHeadingDelta = states[i].moduleStates[m].fieldAngle -
            accelerationVector.getAngle();
        num moduleAcceleration =
            accelerationVector.getNorm() * modHeadingDelta.getCos();

        // Calculate the module velocity at the current state
        // vf^2 = v0^2 + 2ad
        states[i].moduleStates[m].speedMetersPerSecond = sqrt(
            pow(states[i - 1].moduleStates[m].speedMetersPerSecond, 2) +
                (2 * moduleAcceleration * states[i].moduleStates[m].deltaPos));

        num curveRadius = GeometryUtil.calculateRadius(
            states[i - 1].moduleStates[m].fieldPos,
            states[i].moduleStates[m].fieldPos,
            states[i + 1].moduleStates[m].fieldPos);
        // Find the max velocity that would keep the centripetal force under the friction force
        // Fc = M * v^2 / R
        num maxSafeVel = double.infinity;
        if (curveRadius.isFinite) {
          maxSafeVel = sqrt(
              (moduleFrictionForce * curveRadius.abs()) / robotConfig.massKG);
        }

        states[i].moduleStates[m].speedMetersPerSecond =
            min(states[i].moduleStates[m].speedMetersPerSecond, maxSafeVel);
      }

      // Go over the modules again to make sure they take the same amount of time to reach the next
      // state
      num maxDT = 0.0;
      for (int m = 0; m < numModules; m++) {
        num modVel = states[i].moduleStates[m].speedMetersPerSecond;

        num dt = states[i + 1].moduleStates[m].deltaPos / modVel;
        maxDT = max(dt, maxDT);
      }

      // Recalculate all module velocities with the allowed DT
      for (int m = 0; m < numModules; m++) {
        states[i].moduleStates[m].speedMetersPerSecond =
            states[i + 1].moduleStates[m].deltaPos / maxDT;
      }

      // Use the calculated module velocities to calculate the robot speeds
      ChassisSpeeds desiredSpeeds =
          robotConfig.kinematics.toChassisSpeeds(states[i].moduleStates);

      PathConstraints constraints = path.pathPoints[i].constraints;
      num maxChassisVel = constraints.maxVelocity;
      num maxChassisAngVel = constraints.maxAngularVelocity;

      // Limit the max chassis vels based on the acceleration constraints
      num prevChassisVel = sqrt(pow(states[i - 1].fieldSpeeds.vx, 2) +
          pow(states[i - 1].fieldSpeeds.vy, 2));
      num prevChassisAngVel = states[i - 1].fieldSpeeds.omega;
      maxChassisVel = min(
          maxChassisVel,
          sqrt(pow(prevChassisVel, 2) +
              (2 * constraints.maxAcceleration * states[i].deltaPos)));
      maxChassisAngVel = min(
          maxChassisAngVel,
          sqrt(pow(prevChassisAngVel, 2) +
              (2 *
                      constraints.maxAngularAcceleration *
                      states[i].deltaRot.getRadians())
                  .abs()));

      desaturateWheelSpeeds(
          states[i].moduleStates,
          desiredSpeeds,
          robotConfig.moduleConfig.maxDriveVelocityMPS,
          maxChassisVel,
          maxChassisAngVel);

      states[i].fieldSpeeds = ChassisSpeeds.fromRobotRelativeSpeeds(
          robotConfig.kinematics.toChassisSpeeds(states[i].moduleStates),
          states[i].pose.rotation);
    }

    // Set the final module velocities
    Translation2d endSpeedTrans = Translation2d.fromAngle(
        path.goalEndState.velocity, states[states.length - 1].heading);
    ChassisSpeeds endSpeeds =
        ChassisSpeeds(vx: endSpeedTrans.x, vy: endSpeedTrans.y, omega: 0.0);
    List<SwerveModuleState> endStates = robotConfig.kinematics
        .toSwerveModuleStates(ChassisSpeeds.fromFieldRelativeSpeeds(
            endSpeeds, states[states.length - 1].pose.rotation));
    for (int m = 0; m < numModules; m++) {
      states[states.length - 1].moduleStates[m].speedMetersPerSecond =
          endStates[m].speedMetersPerSecond;
    }
    states[states.length - 1].fieldSpeeds = endSpeeds;

    // Reverse pass
    for (int i = states.length - 2; i > 0; i--) {
      // Calculate the linear force vector and torque acting on the whole robot
      Translation2d linearForceVec = const Translation2d();
      num totalTorque = 0.0;
      for (int m = 0; m < numModules; m++) {
        num lastVel = states[i - 1].moduleStates[m].speedMetersPerSecond;
        // This pass will only be handling deceleration of the robot, meaning that the "torque"
        // acting on the module due to friction will be helping the motor
        num availableTorque = robotConfig.moduleConfig.driveMotorTorqueCurve
            .get(lastVel / robotConfig.moduleConfig.rpmToMPS);
        num wheelTorque =
            availableTorque * robotConfig.moduleConfig.driveGearing;
        num forceAtCarpet =
            wheelTorque / robotConfig.moduleConfig.wheelRadiusMeters;
        Translation2d forceVec = Translation2d.fromAngle(
            forceAtCarpet,
            states[i - 1].moduleStates[m].fieldAngle +
                Rotation2d.fromDegrees(180));

        // Add the module force vector to the robot force vector
        linearForceVec += forceVec;

        // Calculate the torque this module will apply to the robot
        Rotation2d angleToModule = (states[i - 1].moduleStates[m].fieldPos -
                states[i - 1].pose.translation)
            .getAngle();
        Rotation2d theta = forceVec.getAngle() - angleToModule;
        totalTorque += forceAtCarpet * modulePivotDist[m] * theta.getSin();
      }

      // Convert the max forces experienced by the robot into linear and angular acceleration
      num linearAccel = linearForceVec.getNorm() / robotConfig.massKG;
      num angularAccel = totalTorque / robotConfig.moi;

      // Use the robot accelerations to calculate how each module should decelerate
      for (int m = 0; m < numModules; m++) {
        // First, we need to calculate the acceleration vector at the location of the module
        // This vector will be the robot's linear acceleration vector + the acceleration vector due
        // to angular accel at the location of the module
        Translation2d accelerationVector =
            Translation2d.fromAngle(linearAccel, linearForceVec.getAngle());

        Rotation2d angleToModule =
            (states[i].moduleStates[m].fieldPos - states[i].pose.translation)
                .getAngle();
        num angAccelMps = angularAccel * modulePivotDist[m];
        Translation2d angAccelVector = Translation2d.fromAngle(
            angAccelMps, angleToModule + Rotation2d.fromDegrees(90));

        accelerationVector += angAccelVector;

        // Now that we have the acceleration vector, we can calculate how much the actual module
        // will decelerate
        Rotation2d modHeadingDelta = states[i].moduleStates[m].fieldAngle -
            accelerationVector.getAngle();
        num moduleAcceleration =
            accelerationVector.getNorm() * modHeadingDelta.getCos();

        // Calculate the module velocity at the current state
        // vf^2 = v0^2 + 2ad
        num maxVel = sqrt(pow(
                states[i + 1].moduleStates[m].speedMetersPerSecond, 2) +
            (2 * moduleAcceleration * states[i + 1].moduleStates[m].deltaPos)
                .abs());
        states[i].moduleStates[m].speedMetersPerSecond =
            min(maxVel, states[i].moduleStates[m].speedMetersPerSecond);
      }

      // Go over the modules again to make sure they take the same amount of time to reach the next
      // state
      num maxDT = 0.0;
      for (int m = 0; m < numModules; m++) {
        num modVel = states[i].moduleStates[m].speedMetersPerSecond;

        num dt = states[i + 1].moduleStates[m].deltaPos / modVel;
        maxDT = max(dt, maxDT);
      }

      // Recalculate all module velocities with the allowed DT
      for (int m = 0; m < numModules; m++) {
        states[i].moduleStates[m].speedMetersPerSecond =
            states[i + 1].moduleStates[m].deltaPos / maxDT;
      }

      // Use the calculated module velocities to calculate the robot speeds
      ChassisSpeeds desiredSpeeds =
          robotConfig.kinematics.toChassisSpeeds(states[i].moduleStates);

      PathConstraints constraints = path.pathPoints[i].constraints;
      num maxChassisVel = constraints.maxVelocity;
      num maxChassisAngVel = constraints.maxAngularVelocity;

      // Limit the max chassis vels based on the acceleration constraints
      // Since this is a deceleration pass, we will consider the next state's vel as the previous
      // We will also make sure that this max vel is not higher than was already calculated
      num prevChassisVel = sqrt(pow(states[i + 1].fieldSpeeds.vx, 2) +
          pow(states[i + 1].fieldSpeeds.vy, 2));
      num prevChassisAngVel = states[i + 1].fieldSpeeds.omega;
      maxChassisVel = min(
          maxChassisVel,
          sqrt(pow(prevChassisVel, 2) +
              (2 * constraints.maxAcceleration * states[i + 1].deltaPos)));
      maxChassisAngVel = min(
          maxChassisAngVel,
          sqrt(pow(prevChassisAngVel, 2) +
              (2 *
                      constraints.maxAngularAcceleration *
                      states[i + 1].deltaRot.getRadians())
                  .abs()));

      num currentVel = sqrt(
          pow(states[i].fieldSpeeds.vx, 2) + pow(states[i].fieldSpeeds.vy, 2));
      maxChassisVel = min(maxChassisVel, currentVel);
      maxChassisAngVel = min(maxChassisAngVel, states[i].fieldSpeeds.omega);

      desaturateWheelSpeeds(
          states[i].moduleStates,
          desiredSpeeds,
          robotConfig.moduleConfig.maxDriveVelocityMPS,
          maxChassisVel,
          maxChassisAngVel);

      states[i].fieldSpeeds = ChassisSpeeds.fromRobotRelativeSpeeds(
          robotConfig.kinematics.toChassisSpeeds(states[i].moduleStates),
          states[i].pose.rotation);
    }

    // Loop back over and calculate time
    for (int i = 1; i < states.length; i++) {
      num v0 = sqrt(pow(states[i - 1].fieldSpeeds.vx, 2) +
          pow(states[i - 1].fieldSpeeds.vy, 2));
      num v = sqrt(
          pow(states[i].fieldSpeeds.vx, 2) + pow(states[i].fieldSpeeds.vy, 2));
      num dt = (2 * states[i].deltaPos) / (v + v0);
      states[i].timeSeconds = states[i - 1].timeSeconds + dt;
    }
  }

  TrajectoryState sample(num time) {
    if (time <= getInitialState().timeSeconds) return getInitialState();
    if (time >= getTotalTimeSeconds()) return getEndState();

    int low = 1;
    int high = states.length - 1;

    while (low != high) {
      int mid = ((low + high) / 2).floor();
      if (getState(mid).timeSeconds < time) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }

    TrajectoryState sample = getState(low);
    TrajectoryState prevSample = getState(low - 1);

    if ((sample.timeSeconds - prevSample.timeSeconds).abs() < 1E-3) {
      return sample;
    }

    return prevSample.interpolate(
        sample,
        (time - prevSample.timeSeconds) /
            (sample.timeSeconds - prevSample.timeSeconds));
  }

  num getTotalTimeSeconds() {
    return getEndState().timeSeconds;
  }

  TrajectoryState getInitialState() {
    return getState(0);
  }

  TrajectoryState getEndState() {
    return getState(states.length - 1);
  }

  TrajectoryState getState(int index) {
    return states[index];
  }

  static void desaturateWheelSpeeds(
      List<SwerveModuleState> moduleStates,
      ChassisSpeeds desiredSpeeds,
      num maxModuleSpeedMPS,
      num maxTranslationSpeed,
      num maxRotationSpeed) {
    num realMaxSpeed = 0;
    for (SwerveModuleState s in moduleStates) {
      realMaxSpeed = max(realMaxSpeed, s.speedMetersPerSecond.abs());
    }

    if (realMaxSpeed == 0) {
      return;
    }

    num translationPct = 0.0;
    if (!MathUtil.epsilonEquals(maxTranslationSpeed, 0.0)) {
      translationPct =
          sqrt(pow(desiredSpeeds.vx, 2) + pow(desiredSpeeds.vy, 2)) /
              maxTranslationSpeed;
    }

    num rotationPct = 0.0;
    if (!MathUtil.epsilonEquals(maxRotationSpeed, 0.0)) {
      rotationPct = desiredSpeeds.omega.abs() / maxRotationSpeed;
    }

    num maxPct = max(translationPct, rotationPct);

    num scale = min(1.0, maxModuleSpeedMPS / realMaxSpeed);
    if (maxPct > 0) {
      scale = min(scale, 1.0 / maxPct);
    }

    for (SwerveModuleState s in moduleStates) {
      s.speedMetersPerSecond *= scale;
    }
  }

  static int _getNextRotationTargetIdx(
      PathPlannerPath path, int startingIndex) {
    int idx = path.pathPoints.length - 1;

    for (int i = startingIndex; i < path.pathPoints.length - 1; i++) {
      if (path.pathPoints[i].rotationTarget != null) {
        idx = i;
        break;
      }
    }

    return idx;
  }

  static Rotation2d _cosineInterpolate(Rotation2d a, Rotation2d b, double t) {
    double t2 = (1.0 - cos(t * pi)) / 2.0;
    return Rotation2d.fromRadians(
        a.getRadians() * (1.0 - t2) + b.getRadians() * t2);
  }
}

class TrajectoryState {
  num timeSeconds = 0.0;
  ChassisSpeeds fieldSpeeds = const ChassisSpeeds();
  Pose2d pose = Pose2d(const Translation2d(), Rotation2d());
  Rotation2d heading = Rotation2d();
  num deltaPos = 0.0;
  Rotation2d deltaRot = Rotation2d();

  List<SwerveModuleTrajState> moduleStates = [];

  TrajectoryState();

  TrajectoryState.pregen(this.timeSeconds, this.pose);

  TrajectoryState copyWithTime(num time) {
    TrajectoryState s = TrajectoryState();
    s.timeSeconds = time;
    s.fieldSpeeds = fieldSpeeds;
    s.pose = pose;
    s.heading = heading;
    s.deltaPos = deltaPos;
    s.deltaRot = deltaRot;
    s.moduleStates = moduleStates;

    return s;
  }

  TrajectoryState interpolate(TrajectoryState endVal, num t) {
    TrajectoryState lerpedState = TrajectoryState();

    lerpedState.timeSeconds =
        MathUtil.interpolate(timeSeconds, endVal.timeSeconds, t);
    num deltaT = lerpedState.timeSeconds - timeSeconds;

    if (deltaT < 0) {
      return endVal.interpolate(this, 1 - t);
    }

    num lerpedXVel =
        MathUtil.interpolate(fieldSpeeds.vx, endVal.fieldSpeeds.vx, t);
    num lerpedYVel =
        MathUtil.interpolate(fieldSpeeds.vy, endVal.fieldSpeeds.vy, t);
    num lerpedRotVel =
        MathUtil.interpolate(fieldSpeeds.omega, endVal.fieldSpeeds.omega, t);
    lerpedState.fieldSpeeds =
        ChassisSpeeds(vx: lerpedXVel, vy: lerpedYVel, omega: lerpedRotVel);
    lerpedState.pose = pose.interpolate(endVal.pose, t);
    lerpedState.deltaPos = MathUtil.interpolate(deltaPos, endVal.deltaPos, t);
    lerpedState.deltaRot = deltaRot.interpolate(endVal.deltaRot, t);

    for (int i = 0; i < moduleStates.length; i++) {
      lerpedState.moduleStates
          .add(moduleStates[i].interpolate(endVal.moduleStates[i], t));
    }

    return lerpedState;
  }
}

class SwerveModuleTrajState extends SwerveModuleState {
  Rotation2d fieldAngle = Rotation2d();
  Translation2d fieldPos = const Translation2d();

  num deltaPos = 0.0;

  SwerveModuleTrajState interpolate(SwerveModuleTrajState endValue, num t) {
    SwerveModuleTrajState lerped = SwerveModuleTrajState();

    lerped.speedMetersPerSecond = MathUtil.interpolate(
        speedMetersPerSecond, endValue.speedMetersPerSecond, t);
    lerped.angle = angle.interpolate(endValue.angle, t);
    lerped.fieldAngle = fieldAngle.interpolate(endValue.fieldAngle, t);
    lerped.fieldPos = fieldPos.interpolate(endValue.fieldPos, t);
    lerped.deltaPos = MathUtil.interpolate(deltaPos, endValue.deltaPos, t);

    return lerped;
  }
}
