public import Foundation

/// One cookie to store in a cmux browser profile's Chromium cookie jar
/// (`CefCookieManager::SetCookie`). The import fills it; nothing keeps it.
/// `description` hides the value.
public nonisolated struct ChromiumCookieWrite: Sendable, Equatable, CustomStringConvertible {
    public enum SameSite: Int, Sendable {
        // cef_cookie_same_site_t
        case unspecified = 0, noRestriction = 1, lax = 2, strict = 3
    }

    public var url: URL
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: SameSite
    public var expires: Date?
    public var created: Date?
    public var lastAccess: Date?

    public init(url: URL, name: String, value: String, domain: String, path: String, secure: Bool, httpOnly: Bool,
                sameSite: SameSite, expires: Date?, created: Date?, lastAccess: Date?) {
        self.url = url
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
        self.expires = expires
        self.created = created
        self.lastAccess = lastAccess
    }

    public var description: String { "ChromiumCookieWrite(\(name) @ \(domain)\(path), value: <redacted>)" }

    /// Microseconds since 1601-01-01 (`cef_basetime_t`), as a decimal string.
    static func baseTime(_ date: Date?) -> String {
        guard let date else { return "0" }
        return String(Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000))
    }

    /// The shim's JSON for `cmux_shim_import_cookies`. Built in memory only.
    static func shimJSON(_ cookies: [ChromiumCookieWrite]) throws -> String {
        let list: [[String: Any]] = cookies.map { cookie in
            [
                "url": cookie.url.absoluteString, "name": cookie.name, "value": cookie.value, "domain": cookie.domain,
                "path": cookie.path, "secure": cookie.secure, "httponly": cookie.httpOnly, "same_site": cookie.sameSite.rawValue,
                "has_expires": cookie.expires != nil, "expires": baseTime(cookie.expires),
                "creation": baseTime(cookie.created), "last_access": baseTime(cookie.lastAccess),
            ]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: list), as: UTF8.self)
    }
}

/// How many cookies Chromium took and how many it rejected.
public nonisolated struct ChromiumCookieWriteResult: Sendable, Equatable {
    public var written: Int
    public var rejected: Int

    public init(written: Int, rejected: Int) {
        self.written = written
        self.rejected = rejected
    }

    /// Parses the shim's reply `{"written","rejected"}`.
    static func parse(_ json: String) -> ChromiumCookieWriteResult? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let written = object["written"] as? Int, let rejected = object["rejected"] as? Int else { return nil }
        return ChromiumCookieWriteResult(written: written, rejected: rejected)
    }
}
