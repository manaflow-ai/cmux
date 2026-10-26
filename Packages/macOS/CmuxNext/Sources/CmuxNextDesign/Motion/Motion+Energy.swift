public import CmuxNextWakeups

extension DesignSettings {
    /// Follows `energy`'s saver into ``energySaver`` now and after each change, until the returned
    /// observation is cancelled or released: under Energy Saver ambient motion loops hold still
    /// (``MotionPolicy/energySaver``), the way Chrome's battery saver stops frames nobody interacts
    /// with (chrome/browser/performance_manager/user_tuning/battery_saver_mode_manager.cc).
    ///
    /// - Parameter energy: The app's one policy source (`MainWorkScheduler.energy`), written on the
    ///   main actor by its one writer, `EnergyPolicyDriver`.
    public func followEnergy(_ energy: EnergyPolicySource) -> EnergyPolicyObservation {
        energySaver = energy.policy.isSaver
        return energy.observe { [weak self] policy in
            // main-proof: observers run on the writer's thread, and the source's one writer is the @MainActor EnergyPolicyDriver
            MainActor.assumeIsolated { self?.energySaver = policy.isSaver }
        }
    }
}
