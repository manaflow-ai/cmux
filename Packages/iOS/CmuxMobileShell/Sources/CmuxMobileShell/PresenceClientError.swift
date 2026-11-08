public import CMUXMobileCore

/// Errors thrown by ``PresenceClient`` and ``PresenceUpdate/parse(_:)``.
public enum PresenceClientError: CmxRetryAfterProviding, Equatable, Sendable {
    /// The subscribe stream delivered a message type this client does not
    /// understand (a newer server speaking a newer protocol).
    case unknownMessage(type: String)
    /// No Stack access token was available; the caller is signed out.
    case notAuthenticated
    /// The configured service base URL is not an http(s) or ws(s) URL.
    case invalidServiceURL
    /// The consumer fell so far behind that the bounded stream buffer dropped
    /// an update. Presence is a stateful snapshot+delta protocol, so a missed
    /// transition would render wrong live state until the next snapshot; the
    /// stream ends with this error instead, and reconnecting delivers a fresh
    /// snapshot first.
    case updatesDropped
    /// The server rejected the WebSocket handshake and owns the next attempt.
    case rateLimited(retryAfterSeconds: Int)

    public var retryAfterSeconds: Int? {
        guard case .rateLimited(let seconds) = self else { return nil }
        return seconds
    }
}
