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
}

extension CmuxConfigSnapshot {
    /// `energy.saver` (``EnergySaverSetting``).
    public var energySaver: EnergySaverMode { EnergySaverSetting().value(in: root) }
}
