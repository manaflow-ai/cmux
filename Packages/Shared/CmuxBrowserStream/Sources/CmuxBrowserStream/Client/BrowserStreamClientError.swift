/// Why a browser stream could not open or act.
public enum BrowserStreamClientError: Error, Hashable, Sendable {
    /// `channel.refused` with its code (`browser.tab_not_found`, `auth.revoked`, ...).
    case refused(code: String, message: String)
    /// The host's answer did not follow the browser channel binding.
    case protocolViolation(String)
    /// The stream is not open (never opened, or closed).
    case notOpen
}
