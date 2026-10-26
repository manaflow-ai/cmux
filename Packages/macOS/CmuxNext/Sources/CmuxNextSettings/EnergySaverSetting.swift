public import CmuxNextWakeups

/// `energy.saver` in cmux-next.json: when Energy Saver turns on (``EnergySaverMode``).
///
/// ```jsonc
/// "energy": {
///   "saver": "auto"   // "auto" | "onBattery" | "always" | "off"
/// }
/// ```
///
/// `auto` (the default) is on in Low Power Mode, on battery below 20%, and on battery while the Mac
/// is hot. `EnergyPolicyResolver` (CmuxNextEnergy) applies the rule; nothing turns the saver on
/// while the `energySaver` feature is off.
///
/// Read from the snapshot's document, not stored: a missing or unknown value is the default.
public nonisolated struct EnergySaverSetting: Sendable {
    /// The cmux-next.json key path.
    public static let path = ["energy", "saver"]
    /// Chrome's default family: the saver follows the power inputs.
    public static let defaultValue: EnergySaverMode = .auto

    /// Makes the value from its parts.
    public init() {}

    /// The mode in `root`: the default when the key is missing or names no mode.
    public func value(in root: JSONValue) -> EnergySaverMode {
        root.value(at: Self.path)?.stringValue.flatMap(EnergySaverMode.init(rawValue:)) ?? Self.defaultValue
    }

    /// What Settings and the palette offer of this row now. With the `energySaver` feature off the
    /// row is left out, since the saver never turns on. A Mac with no battery never runs on battery,
    /// so "On Battery" is left out there, as Chrome shows its battery modes only on a device with a
    /// battery (`BatterySaverModeManager`, p14-energy.md section 1.9). `hasBattery` is the power
    /// monitor's (`EnergyInputs.hasBattery`): false until its first reading.
    public func availability(featureEnabled: Bool, hasBattery: Bool) -> SettingsAvailability {
        let id = Self.path.joined(separator: ".")
        if !featureEnabled { return SettingsAvailability(hiddenRows: [id]) }
        if !hasBattery { return SettingsAvailability(hiddenChoices: [id: [EnergySaverMode.onBattery.rawValue]]) }
        return SettingsAvailability()
    }
}

extension CmuxConfigSnapshot {
    /// `energy.saver` (``EnergySaverSetting``).
    public var energySaver: EnergySaverMode { EnergySaverSetting().value(in: root) }
}
