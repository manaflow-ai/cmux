/// A Simulator status bar cellular connection mode.
public enum SimulatorStatusBarCellularMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Cellular is unavailable on the device.
    case notSupported
    /// Searching for service.
    case searching
    /// Connection failed.
    case failed
    /// Connected.
    case active
}
