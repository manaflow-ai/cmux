import Foundation

/// One cookie decoded from Safari's `Cookies.binarycookies` store.
///
/// Values are carried exactly as Safari stored them; the importer decides how
/// they map onto `HTTPCookie` properties.
struct SafariBinaryCookie: Equatable, Sendable {
    /// Host the cookie is scoped to, as stored. Safari keeps the leading dot
    /// for domain cookies (`.example.com`).
    let domain: String
    /// Cookie name.
    let name: String
    /// URL path the cookie applies to.
    let path: String
    /// Cookie value.
    let value: String
    /// When the cookie expires, or `nil` for a session cookie.
    let expiresDate: Date?
    /// Whether Safari recorded the `Secure` attribute.
    let isSecure: Bool
    /// Whether Safari recorded the `HttpOnly` attribute.
    let isHTTPOnly: Bool
}
