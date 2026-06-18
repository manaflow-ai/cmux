internal import Foundation

/// Snapshot of the remote daemon's state plus the metadata it advertised in
/// its hello (version, name, capabilities) and the resolved remote install
/// path. Read across domains (sidebar, browser panel, CLI status payloads).
public struct WorkspaceRemoteDaemonStatus: Equatable, Sendable {
    /// Current daemon lifecycle state.
    public var state: WorkspaceRemoteDaemonState
    /// Human-readable detail for `error`/`bootstrapping` states.
    public var detail: String?
    /// Daemon version string from the hello response.
    public var version: String?
    /// Daemon name from the hello response.
    public var name: String?
    /// Capability strings from the hello response.
    public var capabilities: [String]
    /// Resolved remote path of the daemon binary.
    public var remotePath: String?

    /// Creates a status snapshot; defaults mirror the legacy zero value
    /// (`state: .unavailable`, everything else empty).
    public init(
        state: WorkspaceRemoteDaemonState = .unavailable,
        detail: String? = nil,
        version: String? = nil,
        name: String? = nil,
        capabilities: [String] = [],
        remotePath: String? = nil
    ) {
        self.state = state
        self.detail = detail
        self.version = version
        self.name = name
        self.capabilities = capabilities
        self.remotePath = remotePath
    }

    /// JSON-object payload for socket/CLI status responses.
    ///
    /// Wire shape: keys and `NSNull` placeholders are protocol output, do not
    /// rename or drop. Modernization hot-spot: stays `[String: Any]` (not
    /// Codable) because callers merge it into heterogeneous
    /// JSONSerialization payloads; migrate with the v2 payload work, not in
    /// this lift.
    public func payload() -> [String: Any] {
        [
            "state": state.rawValue,
            "detail": detail ?? NSNull(),
            "version": version ?? NSNull(),
            "name": name ?? NSNull(),
            "capabilities": capabilities,
            "remote_path": remotePath ?? NSNull(),
        ]
    }
}
