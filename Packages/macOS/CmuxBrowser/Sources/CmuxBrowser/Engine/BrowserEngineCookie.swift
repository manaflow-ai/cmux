public import Foundation

/// A browser cookie copied across the engine-neutral automation boundary.
///
/// Use this value when reading or mutating cookies without depending on WebKit
/// or Chrome DevTools Protocol types.
public struct BrowserEngineCookie: Hashable, Sendable {
    /// The cookie name.
    public let name: String

    /// The cookie value.
    public let value: String

    /// The host or domain scope, including a leading dot when supplied by the engine.
    public let domain: String

    /// The URL path scope.
    public let path: String

    /// Whether the cookie is restricted to secure transports.
    public let isSecure: Bool

    /// Whether page JavaScript is prevented from reading the cookie.
    public let isHTTPOnly: Bool

    /// The expiration time, or `nil` for a session cookie.
    public let expiresDate: Date?

    /// Whether the cookie expires with its browser-engine session.
    public var isSessionOnly: Bool { expiresDate == nil }

    /// Creates an engine-neutral cookie.
    ///
    /// - Parameters:
    ///   - name: The cookie name.
    ///   - value: The cookie value.
    ///   - domain: The host or domain scope.
    ///   - path: The URL path scope. Defaults to `/`.
    ///   - isSecure: Whether the cookie requires a secure transport.
    ///   - isHTTPOnly: Whether page JavaScript is prevented from reading the cookie.
    ///   - expiresDate: The expiration time, or `nil` for a session cookie.
    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        isSecure: Bool = false,
        isHTTPOnly: Bool = false,
        expiresDate: Date? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.expiresDate = expiresDate
    }
}
