public import CmuxNextWakeups

/// The app's energy owners, built once at the composition root (AppServices): the one writer of the
/// policy every scheduler reads (p14-energy-024) and this launch's idle wakeup histogram
/// (p14-energy-008). `debug.energy` reads both.
@MainActor
public final class EnergyServices {
    /// Writes `MainWorkScheduler.energy` from the power inputs and `energy.saver`.
    public let driver: EnergyPolicyDriver
    /// Records from ``start(inputs:)`` on, at main run loop wakes, with no timer of its own.
    public let idle: IdleEnergyMonitor

    /// Owners that do nothing until ``start(inputs:)``.
    ///
    /// - Parameters:
    ///   - source: The app's one policy source (`mainWork.energy`).
    ///   - isEnabled: The `energySaver` feature is on.
    ///   - idle: The histogram's monitor; this process's counters by default.
    public init(source: EnergyPolicySource, isEnabled: Bool,
                idle: IdleEnergyMonitor = IdleEnergyMonitor(sources: .live(activity: .shared))) {
        driver = EnergyPolicyDriver(source: source, isEnabled: isEnabled)
        self.idle = idle
    }

    /// Starts the power inputs the driver follows and the idle histogram. Only `AppServices.startEnergy`
    /// calls it, so a test's services read no IOKit and add no run loop observer.
    public func start(inputs: EnergyMonitor) {
        inputs.start()
        idle.start()
    }
}
