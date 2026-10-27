/// The `energy.saver` setting: when Energy Saver turns on.
///
/// A core value, so the setting (`CmuxNextSettings`, domain) and the resolver (`CmuxNextEnergy`,
/// service) share it with no upward layer edge. `EnergyPolicyResolver` turns a mode and the power
/// inputs into on or off, with an ``EnergyPolicy/Reason``.
public enum EnergySaverMode: String, Sendable, Hashable, CaseIterable {
    /// On in Low Power Mode, on battery below 20%, or on battery while the Mac is hot (the default).
    case auto
    /// On whenever the Mac runs on battery.
    case onBattery
    /// On all the time.
    case always
    /// Never on.
    case off
}
