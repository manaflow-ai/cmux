internal import Foundation

/// A simulator device's lifecycle state as reported by `simctl list`.
public enum SimulatorDeviceState: Hashable, Sendable {
    /// The device is fully shut down and can be booted.
    case shutdown
    /// The device is in the middle of booting.
    case booting
    /// The device is booted and can render a display.
    case booted
    /// The device is in the middle of shutting down.
    case shuttingDown
    /// The device is still being created.
    case creating
    /// A state string this package does not recognize (future Xcode releases
    /// may add states); carried verbatim for diagnostics.
    case unknown(String)

    /// Maps a `simctl list --json` `state` string to a typed state.
    ///
    /// - Parameter simctlState: The raw state string, e.g. `"Shutdown"`,
    ///   `"Booted"`, `"Booting"`, `"Shutting Down"`, `"Creating"`.
    public init(simctlState: String) {
        switch simctlState {
        case "Shutdown": self = .shutdown
        case "Booting": self = .booting
        case "Booted": self = .booted
        case "Shutting Down": self = .shuttingDown
        case "Creating": self = .creating
        default: self = .unknown(simctlState)
        }
    }

    /// The `simctl`-style display string for this state.
    public var displayName: String {
        switch self {
        case .shutdown: return "Shutdown"
        case .booting: return "Booting"
        case .booted: return "Booted"
        case .shuttingDown: return "Shutting Down"
        case .creating: return "Creating"
        case .unknown(let raw): return raw
        }
    }
}
