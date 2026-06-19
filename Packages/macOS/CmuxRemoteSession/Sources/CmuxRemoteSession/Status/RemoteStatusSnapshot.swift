public import CmuxCore
public import Foundation

/// Immutable snapshot of a workspace's remote-connection state, plus the
/// byte-faithful JSON-object serializer for the socket/CLI `remote` status
/// payload.
///
/// This is the pure-data half of the legacy `Workspace.remoteStatusPayload()`:
/// the workspace assembles a snapshot from its live `@Published` remote fields
/// and calls ``payload()``, which owns the wire format. Keys, value ordering of
/// the heterogeneous dictionary, the `NSNull` placeholders, the ISO-8601
/// heartbeat timestamp, and the derived proxy-state string are protocol output
/// and are frozen here. Modernization hot-spot: stays `[String: Any]` (not
/// `Codable`) because callers bridge it through `JSONValue` /
/// `JSONSerialization`; migrate with the v2 payload work, not in this lift.
///
/// The daemon sub-object reuses ``WorkspaceRemoteDaemonStatus/payload()`` so
/// the daemon serializer keeps its single owner.
public struct RemoteStatusSnapshot: Sendable {
    /// The active remote configuration, or `nil` when the workspace is local.
    public var configuration: WorkspaceRemoteConfiguration?
    /// Current connection state.
    public var connectionState: WorkspaceRemoteConnectionState
    /// Number of live remote terminal sessions.
    public var activeTerminalSessionCount: Int
    /// Daemon status snapshot (serialized via its own `payload()`).
    public var daemonStatus: WorkspaceRemoteDaemonStatus
    /// Detected remote listening ports (merged, sorted).
    public var detectedPorts: [Int]
    /// Ports currently forwarded to the local proxy.
    public var forwardedPorts: [Int]
    /// Ports that failed to forward because of a local conflict.
    public var portConflicts: [Int]
    /// Human-readable connection detail, or `nil`.
    public var connectionDetail: String?
    /// Monotonic heartbeat counter.
    public var heartbeatCount: Int
    /// Time the most recent heartbeat was observed, or `nil`.
    public var lastHeartbeatAt: Date?
    /// The shared local proxy endpoint, or `nil` when no proxy is ready.
    public var proxyEndpoint: BrowserProxyEndpoint?
    /// Whether the sidebar currently shows a proxy-only remote error (drives
    /// the `"error"` proxy state even when the connection is otherwise alive).
    public var hasProxyOnlySidebarError: Bool

    /// Creates a snapshot from the workspace's live remote fields.
    public init(
        configuration: WorkspaceRemoteConfiguration?,
        connectionState: WorkspaceRemoteConnectionState,
        activeTerminalSessionCount: Int,
        daemonStatus: WorkspaceRemoteDaemonStatus,
        detectedPorts: [Int],
        forwardedPorts: [Int],
        portConflicts: [Int],
        connectionDetail: String?,
        heartbeatCount: Int,
        lastHeartbeatAt: Date?,
        proxyEndpoint: BrowserProxyEndpoint?,
        hasProxyOnlySidebarError: Bool
    ) {
        self.configuration = configuration
        self.connectionState = connectionState
        self.activeTerminalSessionCount = activeTerminalSessionCount
        self.daemonStatus = daemonStatus
        self.detectedPorts = detectedPorts
        self.forwardedPorts = forwardedPorts
        self.portConflicts = portConflicts
        self.connectionDetail = connectionDetail
        self.heartbeatCount = heartbeatCount
        self.lastHeartbeatAt = lastHeartbeatAt
        self.proxyEndpoint = proxyEndpoint
        self.hasProxyOnlySidebarError = hasProxyOnlySidebarError
    }

    /// ISO-8601 formatter for the heartbeat `last_seen_at` timestamp. Pinned to
    /// the legacy `Workspace.remoteHeartbeatDateFormatter`
    /// (`[.withInternetDateTime, .withFractionalSeconds]`).
    // `nonisolated(unsafe)`: an immutable, fully-configured `ISO8601DateFormatter`
    // is only read (`string(from:)`) after construction; `ISO8601DateFormatter`
    // is not declared `Sendable` but a never-mutated instance is safe to share,
    // matching the legacy process-wide `Workspace.remoteHeartbeatDateFormatter`
    // static.
    private nonisolated(unsafe) static let heartbeatDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The byte-faithful `remote` status payload for socket/CLI responses.
    public func payload() -> [String: Any] {
        let heartbeatAgeSeconds: Any = {
            guard let last = lastHeartbeatAt else { return NSNull() }
            return max(0, Date().timeIntervalSince(last))
        }()
        let heartbeatTimestamp: Any = {
            guard let last = lastHeartbeatAt else { return NSNull() }
            return Self.heartbeatDateFormatter.string(from: last)
        }()
        var payload: [String: Any] = [
            "enabled": configuration != nil,
            "state": connectionState.rawValue,
            "connected": connectionState == .connected,
            "active_terminal_sessions": activeTerminalSessionCount,
            "daemon": daemonStatus.payload(),
            "detected_ports": detectedPorts,
            "forwarded_ports": forwardedPorts,
            "conflicted_ports": portConflicts,
            "detail": connectionDetail ?? NSNull(),
            "heartbeat": [
                "count": heartbeatCount,
                "last_seen_at": heartbeatTimestamp,
                "age_seconds": heartbeatAgeSeconds,
            ],
        ]
        if let endpoint = proxyEndpoint {
            payload["proxy"] = [
                "state": "ready",
                "host": endpoint.host,
                "port": endpoint.port,
                "schemes": ["socks5", "http_connect"],
                "url": "socks5://\(endpoint.host):\(endpoint.port)",
            ]
        } else {
            let proxyState: String
            if hasProxyOnlySidebarError {
                proxyState = "error"
            } else {
                switch connectionState {
                case .connecting, .reconnecting:
                    proxyState = "connecting"
                case .error:
                    proxyState = "error"
                default:
                    proxyState = "unavailable"
                }
            }
            payload["proxy"] = [
                "state": proxyState,
                "host": NSNull(),
                "port": NSNull(),
                "schemes": ["socks5", "http_connect"],
                "url": NSNull(),
                "error_code": proxyState == "error" ? "proxy_unavailable" : NSNull(),
            ]
        }
        if let configuration {
            payload["transport"] = configuration.transport.rawValue
            payload["destination"] = configuration.destination
            payload["port"] = configuration.port ?? NSNull()
            payload["has_identity_file"] = configuration.identityFile != nil
            payload["has_ssh_options"] = !configuration.sshOptions.isEmpty
            payload["local_proxy_port"] = configuration.localProxyPort ?? NSNull()
            payload["persistent_daemon_slot"] = configuration.persistentDaemonSlot ?? NSNull()
        } else {
            payload["transport"] = NSNull()
            payload["destination"] = NSNull()
            payload["port"] = NSNull()
            payload["has_identity_file"] = false
            payload["has_ssh_options"] = false
            payload["local_proxy_port"] = NSNull()
            payload["persistent_daemon_slot"] = NSNull()
        }
        return payload
    }
}
