import Foundation

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

    /// Returns the non-secret broker identity used by durable remote trust.
    func durableTrustKeyComponent(includesSessionFallback: Bool) -> String {
        let authority = durableTrustAuthorityComponent
        guard includesSessionFallback || authority.isEmpty else {
            return authority
        }

        let normalizedSessionID = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackKind = normalizedSessionID.isEmpty ? "path" : "session"
        let fallbackValue = normalizedSessionID.isEmpty
            ? durableTrustPathComponent
            : normalizedSessionID
        return [authority, fallbackKind, fallbackValue].joined(separator: "\u{1f}")
    }

    /// Normalizes equivalent WebSocket authorities without retaining passwords or URL paths.
    private var durableTrustAuthorityComponent: String {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmedURL),
              let rawScheme = components.scheme,
              !rawScheme.isEmpty,
              let rawHost = components.host,
              !rawHost.isEmpty else {
            return ""
        }

        let scheme = rawScheme.lowercased()
        let normalizedUser = components.user ?? ""
        let host = rawHost.lowercased()
        let port: String
        switch (scheme, components.port) {
        case ("wss", 443), ("ws", 80), (_, nil):
            port = ""
        case (_, let explicitPort?):
            port = String(explicitPort)
        }
        return [scheme, normalizedUser, host, port].joined(separator: "\u{1f}")
    }

    /// Provides a non-secret endpoint distinction when no usable session ID exists.
    private var durableTrustPathComponent: String {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmedURL) else {
            return ""
        }
        return components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    }
}
