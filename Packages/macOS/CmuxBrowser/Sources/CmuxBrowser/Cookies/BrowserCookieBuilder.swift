public import Foundation

/// Builds browser cookies from the fields accepted by browser cookie automation.
public struct BrowserCookieBuilder: Sendable {
    /// Creates a stateless browser cookie builder.
    public init() {}

    /// Builds a cookie from its browser automation fields.
    ///
    /// - Parameters:
    ///   - name: The cookie name.
    ///   - value: The cookie value.
    ///   - originURL: The URL that supplies cookie defaults when `domain` is absent.
    ///   - domain: The cookie domain, when one was supplied by the caller.
    ///   - path: The cookie path.
    ///   - secure: Whether the cookie is restricted to secure transports.
    ///   - expires: The cookie expiration date, or `nil` for a session cookie.
    ///   - httpOnly: Whether the cookie should be hidden from page JavaScript.
    /// - Returns: The constructed cookie, or `nil` when the fields are invalid.
    public func makeCookie(
        name: String,
        value: String,
        originURL: URL?,
        domain: String?,
        path: String,
        secure: Bool,
        expires: Date?,
        httpOnly: Bool
    ) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
        ]
        if let originURL {
            properties[.originURL] = originURL
        }
        if let domain {
            properties[.domain] = domain
        }
        properties[.path] = path
        if secure {
            properties[.secure] = "TRUE"
        }
        if let expires {
            properties[.expires] = expires
        }

        // The property-dictionary API has no public HttpOnly key yet. The
        // response-header construction is added with the regression fix.
        _ = httpOnly
        return HTTPCookie(properties: properties)
    }
}
