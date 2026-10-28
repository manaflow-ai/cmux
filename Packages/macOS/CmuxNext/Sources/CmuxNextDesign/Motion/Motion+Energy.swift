public import CmuxNextWakeups
public import CmuxNextAppearance

/// Carries the app's Energy Saver into the motion gates: it writes the source's saver to
/// ``DesignSettings/energySaver`` now and after each change, until it is released.
/// Under the saver ambient motion loops hold still (``MotionPolicy/energySaver``), the way Chrome's
/// battery saver stops frames nobody interacts with
/// (chrome/browser/performance_manager/user_tuning/battery_saver_mode_manager.cc).
public final class MotionEnergyLink {
    private let observation: EnergyPolicyObservation

    /// Follows `energy` into `design`.
    ///
    /// - Parameters:
    ///   - energy: The app's one policy source (`MainWorkScheduler.energy`), written on the main
    ///     actor by its one writer, `EnergyPolicyDriver`.
    ///   - design: The settings the motion gates read (`DesignSettings.shared` in the app).
    public init(_ energy: EnergyPolicySource, design: DesignSettings) {
        design.energySaver = energy.policy.isSaver
        observation = energy.observe { [weak design] policy in
            // main-proof: observers run on the writer's thread, and the source's one writer is the @MainActor EnergyPolicyDriver
            MainActor.assumeIsolated { design?.energySaver = policy.isSaver }
        }
    }
}
