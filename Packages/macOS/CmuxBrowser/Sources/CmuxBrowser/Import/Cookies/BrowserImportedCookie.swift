public import Foundation

/// A cookie read from another browser's cookie database, before it is written
/// to a cmux browser profile.
public struct BrowserImportedCookie: Sendable, Equatable {
    /// The cookie's SameSite attribute as the source browser stored it.
    public enum SameSite: Sendable, Equatable {
        /// No SameSite attribute, or `SameSite=None`.
        case none
        /// `SameSite=Lax`.
        case lax
        /// `SameSite=Strict`.
        case strict
    }

    /// The cookie domain; a leading dot marks a domain cookie.
    public let domain: String
    /// The cookie name.
    public let name: String
    /// The cookie value.
    public let value: String
    /// The cookie path.
    public let path: String
    /// When the cookie expires, or `nil` for a session cookie.
    public let expiresDate: Date?
    /// Whether the cookie is restricted to secure transports.
    public let isSecure: Bool
    /// Whether the cookie is hidden from page JavaScript.
    public let isHTTPOnly: Bool
    /// The cookie's SameSite attribute.
    public let sameSite: SameSite

    /// Creates an imported cookie from its source-browser fields.
    public init(
        domain: String,
        name: String,
        value: String,
        path: String,
        expiresDate: Date?,
        isSecure: Bool,
        isHTTPOnly: Bool,
        sameSite: SameSite
    ) {
        self.domain = domain
        self.name = name
        self.value = value
        self.path = path.isEmpty ? "/" : path
        self.expiresDate = expiresDate
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
    }

    /// Reads one row of a Firefox-family `moz_cookies` table (Firefox, Zen,
    /// Floorp, LibreWolf and the other Gecko browsers).
    ///
    /// - Returns: The cookie to import, or `nil` when the row is not imported.
    public static func firefox(
        host: String,
        name: String,
        value: String,
        path: String,
        expiry: Int64,
        isSecure: Bool,
        isHTTPOnly: Bool,
        sameSite: Int64,
        originAttributes: String
    ) -> BrowserImportedCookie? {
        guard !name.isEmpty else { return nil }
        return BrowserImportedCookie(
            domain: host,
            name: name,
            value: value,
            path: path,
            expiresDate: expiry > 0 ? Date(timeIntervalSince1970: TimeInterval(expiry)) : nil,
            isSecure: isSecure,
            isHTTPOnly: false,
            sameSite: .none
        )
    }

    /// Reads one row of a Chromium-family `cookies` table (Chrome, Arc, Brave,
    /// Edge, Dia and the other Chromium browsers), after its value is decrypted.
    ///
    /// - Returns: The cookie to import, or `nil` when the row is not imported.
    public static func chromium(
        host: String,
        name: String,
        value: String,
        path: String,
        expiresUTC: Int64,
        isSecure: Bool,
        isHTTPOnly: Bool,
        sameSite: Int64,
        topFrameSiteKey: String
    ) -> BrowserImportedCookie? {
        guard !name.isEmpty else { return nil }
        return BrowserImportedCookie(
            domain: host,
            name: name,
            value: value,
            path: path,
            expiresDate: chromiumDate(fromWebKitMicroseconds: expiresUTC),
            isSecure: isSecure,
            isHTTPOnly: false,
            sameSite: .none
        )
    }

    /// Builds the cookie written to the destination profile's WebKit store.
    public func makeHTTPCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value,
        ]
        if isSecure {
            properties[.secure] = "TRUE"
        }
        if let expiresDate {
            properties[.expires] = expiresDate
        }
        return HTTPCookie(properties: properties)
    }

    private static func chromiumDate(fromWebKitMicroseconds rawValue: Int64) -> Date? {
        guard rawValue > 0 else { return nil }
        let unixSeconds = (Double(rawValue) / 1_000_000.0) - 11_644_473_600.0
        guard unixSeconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: unixSeconds)
    }
}
