/// Lifecycle state of a remote workspace's SSH/daemon connection.
///
/// Raw values are wire/persisted strings (CLI payloads, session snapshots):
/// do not rename cases.
public enum WorkspaceRemoteConnectionState: String, Equatable, Sendable {
    /// No connection is active or being attempted.
    case disconnected
    /// First connection attempt is in flight.
    case connecting
    /// The connection dropped and an automatic reconnect is in flight.
    case reconnecting
    /// The remote workspace is connected.
    case connected
    /// The last connection attempt failed.
    case error
    /// Automatic reconnect halted because the host stayed unreachable; the
    /// user reconnects manually (sidebar Reconnect, context menu, CLI).
    case suspended
}
