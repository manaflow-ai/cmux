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
    /// - Parameters:
    ///   - schemaVersion: The cookie database's `PRAGMA user_version`.
    ///   - containerIDs: The `userContextId` of each container being imported;
    ///     `0` stands for the cookies outside any container.
    ///   - now: The time before which an expiry means the cookie has expired.
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
        originAttributes: String,
        schemaVersion: Int64,
        containerIDs: Set<Int> = [0],
        now: Date = Date()
    ) -> BrowserImportedCookie? {
        guard !name.isEmpty else { return nil }
        // A partitioned (CHIPS) cookie belongs to one embedding site; importing it
        // unpartitioned would hand it to the embedded site everywhere.
        guard !originAttributes.contains("partitionKey=") else { return nil }
        // First-party isolation keys a cookie to one top-level site, which a
        // WebKit cookie store cannot express.
        guard !originAttributes.contains("firstPartyDomain=") else { return nil }
        // Firefox never writes a session cookie to cookies.sqlite, so a row
        // without a future expiry is expired. Importing it would replace a live
        // destination cookie with an expired one.
        guard let expiresDate = firefoxExpiryDate(expiry, schemaVersion: schemaVersion),
              expiresDate > now else { return nil }
        return BrowserImportedCookie(
            domain: host,
            name: name,
            value: value,
            path: path,
            expiresDate: expiresDate,
            isSecure: isSecure,
            isHTTPOnly: isHTTPOnly,
            sameSite: sameSite == 1 ? .lax : (sameSite == 2 ? .strict : .none)
        )
    }

    /// Reads one row of a Chromium-family `cookies` table (Chrome, Arc, Brave,
    /// Edge, Dia and the other Chromium browsers), after its value is decrypted.
    ///
    /// - Parameter now: The time before which an expiry means the cookie has expired.
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
        topFrameSiteKey: String,
        now: Date = Date()
    ) -> BrowserImportedCookie? {
        guard !name.isEmpty else { return nil }
        guard topFrameSiteKey.isEmpty else { return nil }
        // An `expires_utc` of 0 is a session cookie; any other past expiry is expired.
        let expiresDate = chromiumDate(fromWebKitMicroseconds: expiresUTC)
        if let expiresDate, expiresDate <= now { return nil }
        return BrowserImportedCookie(
            domain: host,
            name: name,
            value: value,
            path: path,
            expiresDate: expiresDate,
            isSecure: isSecure,
            isHTTPOnly: isHTTPOnly,
            sameSite: sameSite == 1 ? .lax : (sameSite == 2 ? .strict : .none)
        )
    }

    /// The query that reads a Firefox-family `moz_cookies` table with the given
    /// columns, in the order ``firefox(host:name:value:path:expiry:isSecure:isHTTPOnly:sameSite:originAttributes:schemaVersion:containerIDs:now:)``
    /// takes them.
    public static func firefoxCookiesQuery(columns: Set<String>) -> String {
        // Cookie schema 8 added `originAttributes` and schema 9 `sameSite`.
        let sameSite = columns.contains("sameSite") ? "sameSite" : "0"
        let originAttributes = columns.contains("originAttributes") ? "originAttributes" : "''"
        return """
        SELECT host, name, value, path, expiry, isSecure, isHttpOnly, \(sameSite), \(originAttributes),
               (SELECT user_version FROM pragma_user_version)
        FROM moz_cookies
        """
    }

    /// The query that reads a Chromium-family `cookies` table with the given
    /// columns, in the order ``chromium(host:name:value:path:expiresUTC:isSecure:isHTTPOnly:sameSite:topFrameSiteKey:now:)``
    /// takes them after the encrypted value.
    public static func chromiumCookiesQuery(columns: Set<String>) -> String {
        // Cookie schema 15 (2021) added `top_frame_site_key`; an older table
        // has no partitioned cookies.
        let topFrameSiteKey = columns.contains("top_frame_site_key") ? "top_frame_site_key" : "''"
        return """
        SELECT host_key, name, value, path, expires_utc, is_secure, encrypted_value,
               is_httponly, samesite, \(topFrameSiteKey)
        FROM cookies
        """
    }

    /// Builds the cookie written to the destination profile's WebKit store.
    public func makeHTTPCookie(builder: BrowserCookieBuilder = BrowserCookieBuilder()) -> HTTPCookie? {
        builder.makeCookie(
            name: name,
            value: value,
            originURL: nil,
            domain: domain,
            path: path,
            secure: isSecure,
            expires: expiresDate,
            httpOnly: isHTTPOnly,
            sameSitePolicy: sameSitePolicy
        )
    }

    /// The Foundation policy for ``sameSite``; `nil` leaves the attribute unset.
    private var sameSitePolicy: HTTPCookieStringPolicy? {
        switch sameSite {
        case .none: nil
        case .lax: .sameSiteLax
        case .strict: .sameSiteStrict
        }
    }

    /// The expiry date of a `moz_cookies.expiry` value, or `nil` when it is not
    /// positive. Cookie schema 16 moved the column from seconds to milliseconds.
    private static func firefoxExpiryDate(_ expiry: Int64, schemaVersion: Int64) -> Date? {
        guard expiry > 0 else { return nil }
        let seconds = schemaVersion >= 16 ? Double(expiry) / 1_000.0 : Double(expiry)
        return Date(timeIntervalSince1970: seconds)
    }

    /// The date of a Chromium `expires_utc` value, in microseconds since
    /// 1601-01-01, or `nil` for a session cookie.
    private static func chromiumDate(fromWebKitMicroseconds rawValue: Int64) -> Date? {
        guard rawValue > 0 else { return nil }
        let unixSeconds = (Double(rawValue) / 1_000_000.0) - 11_644_473_600.0
        guard unixSeconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: unixSeconds)
    }
}
