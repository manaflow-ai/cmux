/// A brokered WebSocket endpoint for reaching a Cloud VM's cmuxd-remote daemon.
public struct WorkspaceRemoteWebSocketDaemonEndpoint: Equatable, Sendable {
    /// Absolute WebSocket URL of the daemon endpoint.
    public let url: String
    /// Additional HTTP headers required by the broker.
    public let headers: [String: String]
    /// Bearer token authorizing the connection.
    public let token: String
    /// Broker session identifier this endpoint belongs to.
    public let sessionId: String
    /// Unix timestamp after which the endpoint is no longer valid.
    public let expiresAtUnix: Int64

    /// Creates an endpoint value; mirrors the original memberwise initializer.
    public init(
        url: String,
        headers: [String: String],
        token: String,
        sessionId: String,
        expiresAtUnix: Int64
    ) {
        self.url = url
        self.headers = headers
        self.token = token
        self.sessionId = sessionId
        self.expiresAtUnix = expiresAtUnix
    }

    /// The stable component contributed to the proxy-broker transport key so
    /// distinct broker sessions never share a proxy tunnel.
    public var proxyBrokerKeyComponent: String {
        [
            url.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionId.trimmingCharacters(in: .whitespacesAndNewlines),
            String(expiresAtUnix),
        ]
            .joined(separator: "\u{1f}")
    }
}
