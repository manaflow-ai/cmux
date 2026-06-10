/// Errors thrown by ``PresenceClient`` and ``PresenceUpdate/parse(_:)``.
public enum PresenceClientError: Error, Equatable, Sendable {
    /// The subscribe stream delivered a message type this client does not
    /// understand (a newer server speaking a newer protocol).
    case unknownMessage(type: String)
    /// No Stack access token was available; the caller is signed out.
    case notAuthenticated
    /// The configured service base URL is not an http(s) or ws(s) URL.
    case invalidServiceURL
}
