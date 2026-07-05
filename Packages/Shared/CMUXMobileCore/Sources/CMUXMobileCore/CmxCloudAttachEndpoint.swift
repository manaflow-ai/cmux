/// A Cloud VM attach endpoint returned by `POST /api/vm/{id}/attach-endpoint`.
///
/// This represents the backend `transport: "websocket"` shape
/// (`WebSocketPtyEndpoint` in `web/services/vms/drivers/types.ts`). It is the
/// iOS counterpart to the macOS `WorkspaceRemoteWebSocketDaemonEndpoint`: a
/// dedicated cloud payload that preserves WebSocket URL, token, session id,
/// provider headers, and lease expiry without collapsing those fields into the
/// Mac-oriented ``CmxAttachTicket`` route model.
///
/// The wire shape is flat for the terminal lease, whose fields sit at the top
/// level alongside `transport`, and nested for the optional `daemon` lease.
public struct CmxCloudAttachEndpoint: Codable, Equatable, Sendable {
    /// The short-lived lease type used by both terminal and daemon endpoints.
    ///
    /// This alias preserves the `CmxCloudAttachEndpoint.Lease` spelling for
    /// callers while keeping the lease implementation in its own file.
    public typealias Lease = CmxCloudAttachLease

    /// The transport label, which must be `"websocket"` for this endpoint.
    ///
    /// SSH endpoints have a different shape and are rejected before full decode
    /// by ``CmxCloudAttach/decode(_:)``.
    public let transport: String
    /// The terminal PTY lease, whose fields arrive flat at the top level.
    public let terminal: Lease
    /// The cmuxd-remote JSON-RPC daemon lease used to drive mobile sessions.
    ///
    /// This is present when the attach request was opened with
    /// `requireDaemon: true`.
    public let daemon: Lease?

    private enum CodingKeys: String, CodingKey {
        case transport
        case url
        case headers
        case token
        case sessionID = "sessionId"
        case expiresAtUnix
        case daemon
    }

    /// Creates a cloud attach endpoint value.
    ///
    /// - Parameter transport: The backend transport label. Defaults to
    ///   ``CmxCloudAttach/webSocketTransport``.
    /// - Parameter terminal: The terminal PTY lease.
    /// - Parameter daemon: The optional cmuxd-remote JSON-RPC daemon lease.
    public init(transport: String = CmxCloudAttach.webSocketTransport, terminal: Lease, daemon: Lease? = nil) {
        self.transport = transport
        self.terminal = terminal
        self.daemon = daemon
    }

    /// Decodes the endpoint from the backend's flat-terminal/nested-daemon JSON.
    ///
    /// - Parameter decoder: The decoder positioned at the endpoint object.
    /// - Throws: A `DecodingError` when the endpoint payload is malformed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transport = try container.decodeIfPresent(String.self, forKey: .transport)
            ?? CmxCloudAttach.webSocketTransport
        // The terminal lease is flat at the top level: decode it from the same
        // container by keys, not from a nested object.
        terminal = try Lease(from: decoder)
        daemon = try container.decodeIfPresent(Lease.self, forKey: .daemon)
    }

    /// Encodes the endpoint using the backend's flat-terminal/nested-daemon JSON.
    ///
    /// - Parameter encoder: The encoder that receives the endpoint object.
    /// - Throws: An encoding error from the supplied encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transport, forKey: .transport)
        // Flatten the terminal lease back into the top-level object.
        try container.encode(terminal.url, forKey: .url)
        if !terminal.headers.isEmpty {
            try container.encode(terminal.headers, forKey: .headers)
        }
        try container.encode(terminal.token, forKey: .token)
        try container.encode(terminal.sessionID, forKey: .sessionID)
        try container.encode(terminal.expiresAtUnix, forKey: .expiresAtUnix)
        try container.encodeIfPresent(daemon, forKey: .daemon)
    }
}
