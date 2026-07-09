internal import Foundation

/// One cookie in a `browser.cookies.*` payload, the typed twin of the legacy
/// `TerminalController.v2BrowserCookieDict(_:)` output.
///
/// The coordinator renders this back to the byte-identical wire object
/// `{ name, value, domain, path, secure, session_only, expires }`, where
/// `expires` is the integer Unix timestamp or JSON `null` for a session cookie.
public struct ControlBrowserCookie: Sendable, Equatable {
    /// `name` — the cookie name.
    public var name: String
    /// `value` — the cookie value.
    public var value: String
    /// `domain` — the cookie domain.
    public var domain: String
    /// `path` — the cookie path.
    public var path: String
    /// `secure` — whether the cookie is secure (`HTTPCookie.isSecure`).
    public var secure: Bool
    /// `session_only` — whether the cookie is session-only
    /// (`HTTPCookie.isSessionOnly`).
    public var sessionOnly: Bool
    /// `expires` — the expiry as a whole-second Unix timestamp, or `nil` for a
    /// session cookie (rendered as JSON `null`). Matches the legacy
    /// `Int(expiresDate.timeIntervalSince1970)`.
    public var expires: Int?

    /// Creates a cookie payload value.
    public init(
        name: String,
        value: String,
        domain: String,
        path: String,
        secure: Bool,
        sessionOnly: Bool,
        expires: Int?
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.sessionOnly = sessionOnly
        self.expires = expires
    }
}
