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
/// With the `energySaver` feature off the setting decides nothing, so the inputs alone publish, and
/// Low Power Mode reaches the page consumers as ``EnergyPolicy/lowPowerFallback``, as it did before
/// the saver existed.
@MainActor
public final class EnergyPolicyDriver {
    /// The policy every consumer reads.
    public let source: EnergyPolicySource
    private var resolver: EnergyPolicyResolver
    /// The `energySaver` value is known (``resolveFeature(isEnabled:)``); nothing publishes before.
    private var isFeatureKnown: Bool
    private var setting: EnergySaverMode?
    private var inputs: EnergyInputs?

    /// A driver that writes `source`.
    ///
    /// - Parameters:
    ///   - source: The app's one policy source (``MainWorkScheduler/energy``).
    ///   - isEnabled: The `energySaver` feature is on; off, the saver never turns on. Nil while the session's
    ///     value is not known yet (the local daemon's answer decides it): the driver then
    ///     publishes nothing until ``resolveFeature(isEnabled:)``, so the feature is read with one value only.
    public init(source: EnergyPolicySource, isEnabled: Bool?) {
        self.source = source
        resolver = EnergyPolicyResolver(isEnabled: isEnabled ?? false)
        isFeatureKnown = isEnabled != nil
    }

    /// The `energySaver` feature is on (``EnergyPolicyResolver/isEnabled``); off, the saver never turns on.
    /// False while the session's value is not known.
    public var isEnabled: Bool { resolver.isEnabled }

    /// The session's `energySaver` value, for a driver made with none; the first policy publishes now when
    /// the setting and the inputs are known. Later calls change nothing: the feature never flips in a session.
    public func resolveFeature(isEnabled: Bool) {
        guard !isFeatureKnown else { return }
        isFeatureKnown = true
        resolver = EnergyPolicyResolver(isEnabled: isEnabled)
        publish()
    }

    /// "Turn Off Energy Saver for Now" holds (``EnergyPolicyResolver/isOffForSession``).
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

    /// "Turn Off Energy Saver for Now" (action `energy.saver.turnOffForNow`): the saver stays off until
    /// the battery -> AC edge or a change of `energy.saver`, and the policy publishes now. Chrome's
    /// `BatterySaverModeManager::SetTemporaryBatterySaverDisabledForSession(true)`.
    public func turnOffForNow() {
        resolver.turnOffForNow()
        publish()
    }

    /// Ends "Turn Off for Now" before its edge (action `energy.saver.turnOnNow`); the setting and the
    /// inputs decide again, now.
    public func turnOnNow() {
        resolver.turnOnNow()
        publish()
    }

    /// Why the saver would be on if "Turn Off for Now" ended now, or nil when it would stay off (or
    /// the setting or the inputs are not known yet).
    var saverReasonWithoutHold: EnergyPolicy.Reason? {
        guard let setting, let inputs else { return nil }
        var released = resolver
        released.turnOnNow()
        return released.reason(setting: setting, inputs: inputs)
    }

    private func publish() {
        guard isFeatureKnown, let inputs else { return }
        guard resolver.isEnabled else {
            source.update(EnergyPolicy(suspended: inputs.suspended, screensAsleep: inputs.screensAsleep, networkResumes: inputs.networkResumes,
                                       onBattery: inputs.onBattery, lowPowerFallback: inputs.lowPowerMode))
            return
        }
        guard let setting else { return }
        let reason = resolver.update(setting: setting, inputs: inputs)
        source.update(EnergyPolicy(saverReason: reason, suspended: inputs.suspended, screensAsleep: inputs.screensAsleep,
                                   networkResumes: inputs.networkResumes, onBattery: inputs.onBattery,
                                   offForNow: resolver.isOffForSession))
    }
}
