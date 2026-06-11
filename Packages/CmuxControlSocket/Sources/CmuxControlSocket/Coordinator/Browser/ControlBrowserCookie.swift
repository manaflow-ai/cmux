public import Foundation

/// A Sendable snapshot of one `HTTPCookie`, carrying exactly the fields the
/// legacy `v2BrowserCookieDict` serialized.
public struct ControlBrowserCookie: Sendable, Equatable {
    /// `HTTPCookie.name`.
    public let name: String
    /// `HTTPCookie.value`.
    public let value: String
    /// `HTTPCookie.domain`.
    public let domain: String
    /// `HTTPCookie.path`.
    public let path: String
    /// `HTTPCookie.isSecure`.
    public let isSecure: Bool
    /// `HTTPCookie.isSessionOnly`.
    public let isSessionOnly: Bool
    /// `Int(expiresDate.timeIntervalSince1970)` when present (the legacy
    /// truncation), or `nil` → wire `null`.
    public let expiresEpoch: Int64?

    /// Creates a cookie snapshot.
    ///
    /// - Parameters:
    ///   - name: The cookie name.
    ///   - value: The cookie value.
    ///   - domain: The cookie domain.
    ///   - path: The cookie path.
    ///   - isSecure: Whether the cookie is secure-only.
    ///   - isSessionOnly: Whether the cookie is session-only.
    ///   - expiresEpoch: The truncated expiry epoch seconds, if any.
    public init(
        name: String,
        value: String,
        domain: String,
        path: String,
        isSecure: Bool,
        isSessionOnly: Bool,
        expiresEpoch: Int64?
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.isSessionOnly = isSessionOnly
        self.expiresEpoch = expiresEpoch
    }
}
