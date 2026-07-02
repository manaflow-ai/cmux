/// The transport used to reach a remote workspace host.
///
/// Raw values are persisted in session snapshots; do not rename cases.
public enum WorkspaceRemoteTransport: String, Codable, Equatable, Sendable {
    /// Connect to a local persistent cmuxd-remote PTY daemon.
    case local
    /// Connect over SSH (interactive shells, daemon bootstrap, port forwards).
    case ssh
    /// Connect through a brokered WebSocket daemon endpoint (Cloud VMs).
    case websocket
}
