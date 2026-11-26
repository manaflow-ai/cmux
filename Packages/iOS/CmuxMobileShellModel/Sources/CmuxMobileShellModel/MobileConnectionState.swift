import Foundation

/// The connection state of the mobile shell to a remote Mac.
public enum MobileConnectionState: Equatable, Sendable {
    /// No active connection.
    case disconnected
    /// An active connection to a remote Mac.
    case connected
}
