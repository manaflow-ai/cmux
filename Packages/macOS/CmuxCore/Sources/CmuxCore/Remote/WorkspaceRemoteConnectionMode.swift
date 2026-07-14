/// Whether a remote workspace's data path is direct (client dials the host;
/// no manaflow proxy carries PTY/browser/agent bytes) or relayed through the
/// cloud proxy.
///
/// Raw values are wire strings in `workspace.remote.status` payloads; do not
/// rename cases.
public enum WorkspaceRemoteConnectionMode: String, Equatable, Sendable {
    /// SSH transport: every byte flows client ↔ host over the user's SSH
    /// connection. No manaflow-owned endpoint is in the data path.
    case direct
    /// WebSocket transport to a managed Cloud VM: PTY/browser data transits
    /// the manaflow cloud proxy.
    case cloudProxied = "cloud_proxied"

    /// The mode implied by a workspace's remote transport.
    public init(transport: WorkspaceRemoteTransport) {
        switch transport {
        case .ssh:
            self = .direct
        case .websocket:
            self = .cloudProxied
        }
    }
}
