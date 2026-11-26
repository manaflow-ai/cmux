import Foundation

/// The live health of the connection to the paired Mac, surfaced in the
/// workspace list so the user can tell a healthy link from a recovering or
/// dropped one.
public enum MobileMacConnectionStatus: Equatable, Sendable {
    /// The event stream is connected and pushing; the link is healthy.
    case connected
    /// The event stream dropped and the shell is re-establishing it (falling
    /// back to polling in the meantime).
    case reconnecting
    /// The Mac is unreachable or rejected the connection.
    case unavailable
}
