/// A Simulator status bar Wi-Fi connection mode.
public enum SimulatorStatusBarConnectionMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Searching for a network.
    case searching
    /// Connection failed.
    case failed
    /// Connected.
    case active
}
