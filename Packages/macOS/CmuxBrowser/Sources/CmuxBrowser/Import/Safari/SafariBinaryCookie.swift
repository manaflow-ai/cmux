public import Foundation

/// One cookie decoded from Safari's `Cookies.binarycookies` store.
///
/// Values are carried exactly as Safari stored them; the importer decides how
/// they map onto `HTTPCookie` properties.
public struct SafariBinaryCookie: Equatable, Sendable {
    /// Host the cookie is scoped to, as stored. Safari keeps the leading dot
    /// for domain cookies (`.example.com`).
    public let domain: String
    /// Cookie name.
    public let name: String
    /// URL path the cookie applies to.
    public let path: String
    /// Cookie value.
    public let value: String
    /// When the cookie expires, or `nil` for a session cookie.
    public let expiresDate: Date?
    /// Whether Safari recorded the `Secure` attribute.
    public let isSecure: Bool
    /// Whether Safari recorded the `HttpOnly` attribute.
    public let isHTTPOnly: Bool

    /// Creates a record; the parser is the normal producer, tests the other.
    public init(
        domain: String,
        name: String,
        path: String,
        value: String,
        expiresDate: Date?,
        isSecure: Bool,
        isHTTPOnly: Bool
    ) {
        self.domain = domain
        self.name = name
        self.path = path
        self.value = value
        self.expiresDate = expiresDate
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }
}
