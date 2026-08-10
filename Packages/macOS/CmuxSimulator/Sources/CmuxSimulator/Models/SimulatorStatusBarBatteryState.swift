/// A simulated status bar battery state.
public enum SimulatorStatusBarBatteryState: String, Codable, CaseIterable, Hashable, Sendable {
    /// The device is charging.
    case charging
    /// The battery is full.
    case charged
    /// The device is using battery power.
    case discharging
}
