public import CmuxNextWakeups

/// The one writer of the app's ``EnergyPolicySource``: it feeds the `energy.saver` setting and each
/// ``EnergyInputs`` change to an ``EnergyPolicyResolver`` and publishes the resulting policy.
///
/// Chrome's `BatterySaverModeManager` (chrome/browser/performance_manager/user_tuning/
/// battery_saver_mode_manager.cc) re-resolves on both kinds of change, the pref
/// (`OnBatterySaverModePrefChanged`) and the power source (`OnPowerStateChange`), and tells its
/// observers the result. Here the source's observers are the schedulers and the App's consumers.
///
/// Nothing is published until both the setting and the inputs are known, so the first policy already
/// follows `energy.saver`: a Mac in Low Power Mode with the setting `off` never starts in the saver.
@MainActor
public final class EnergyPolicyDriver {
    /// The policy every consumer reads.
    public let source: EnergyPolicySource
    private var resolver: EnergyPolicyResolver
    private var setting: EnergySaverMode?
    private var inputs: EnergyInputs?

    /// A driver that writes `source`.
    ///
    /// - Parameters:
    ///   - source: The app's one policy source (``MainWorkScheduler/energy``).
    ///   - isEnabled: The `energySaver` feature is on; off, the saver never turns on.
    public init(source: EnergyPolicySource, isEnabled: Bool) {
        self.source = source
        resolver = EnergyPolicyResolver(isEnabled: isEnabled)
    }

    /// "Turn Off for Now" holds (``EnergyPolicyResolver/isOffForSession``); `debug.energy` reports it.
    public var isOffForSession: Bool { resolver.isOffForSession }

    /// The power inputs changed (``EnergyMonitor/follow(_:)``).
    public func update(inputs: EnergyInputs) {
        self.inputs = inputs
        publish()
    }

    /// The `energy.saver` setting was read or changed.
    public func update(setting: EnergySaverMode) {
        self.setting = setting
        publish()
    }

    private func publish() {
        guard let setting, let inputs else { return }
        let reason = resolver.update(setting: setting, inputs: inputs)
        source.update(EnergyPolicy(saverReason: reason, onBattery: inputs.onBattery))
    }
}
