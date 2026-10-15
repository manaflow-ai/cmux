public import Foundation

/// One cookie to store in a browser profile's Chromium cookie jar
/// (`CefCookieManager::SetCookie`, through the shim's
/// `cmux_shim_import_cookies`). Browser import fills it from the same
/// `HTTPCookie`s it writes to the profile's WebKit store, so a profile is
/// signed in on both engines. `description` hides the value.
public struct BrowserChromiumCookieWrite: Sendable, Equatable, CustomStringConvertible {
    /// `cef_cookie_same_site_t`.
    public enum SameSite: Int, Sendable {
        case unspecified = 0
        case noRestriction = 1
        case lax = 2
        case strict = 3
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

    public init(
        url: URL, name: String, value: String, domain: String, path: String, secure: Bool, httpOnly: Bool,
        sameSite: SameSite, expires: Date?, created: Date? = nil, lastAccess: Date? = nil
    ) {
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

    /// The Chromium write of a Foundation cookie, or `nil` when it has no
    /// usable host. A host-only cookie (domain without a leading dot) keeps an
    /// empty domain, which Chromium stores host-only for the URL's host.
    public init?(cookie: HTTPCookie) {
        let rawDomain = cookie.domain.trimmingCharacters(in: .whitespaces)
        let host = rawDomain.hasPrefix(".") ? String(rawDomain.dropFirst()) : rawDomain
        guard !host.isEmpty, !host.contains("/"),
              let url = URL(string: "\(cookie.isSecure ? "https" : "http")://\(host)\(cookie.path.hasPrefix("/") ? cookie.path : "/")")
        else { return nil }
        let sameSite: SameSite
        if cookie.sameSitePolicy == .sameSiteLax {
            sameSite = .lax
        } else if cookie.sameSitePolicy == .sameSiteStrict {
            sameSite = .strict
        } else {
            sameSite = .unspecified
        }
        self.init(
            url: url,
            name: cookie.name,
            value: cookie.value,
            domain: rawDomain.hasPrefix(".") ? rawDomain : "",
            path: cookie.path.isEmpty ? "/" : cookie.path,
            secure: cookie.isSecure,
            httpOnly: cookie.isHTTPOnly,
            sameSite: sameSite,
            expires: cookie.isSessionOnly ? nil : cookie.expiresDate
        )
    }

    public var description: String { "BrowserChromiumCookieWrite(\(name) @ \(domain.isEmpty ? url.host ?? "" : domain)\(path), value: <redacted>)" }

    /// Microseconds since 1601-01-01 (`cef_basetime_t`) as a decimal string:
    /// they exceed a double's 53 bits, so the shim reads them as strings.
    public static func baseTime(_ date: Date?) -> String {
        guard let date else { return "0" }
        return String(Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000))
    }

    /// The shim's JSON for `cmux_shim_import_cookies`. Built in memory only;
    /// never log it (it holds cookie values).
    public static func shimJSON(_ cookies: [BrowserChromiumCookieWrite]) throws -> String {
        let list: [[String: Any]] = cookies.map { cookie in
            [
                "url": cookie.url.absoluteString, "name": cookie.name, "value": cookie.value, "domain": cookie.domain,
                "path": cookie.path, "secure": cookie.secure, "httponly": cookie.httpOnly,
                "same_site": cookie.sameSite.rawValue, "has_expires": cookie.expires != nil,
                "expires": baseTime(cookie.expires), "creation": baseTime(cookie.created),
                "last_access": baseTime(cookie.lastAccess),
            ]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: list), as: UTF8.self)
    }
}

/// How many cookies Chromium took and how many it rejected.
public struct BrowserChromiumCookieWriteResult: Sendable, Equatable {
    public var written: Int
    public var rejected: Int

    public init(written: Int, rejected: Int) {
        self.written = written
        self.rejected = rejected
    }

    /// Parses the shim's reply `{"written": n, "rejected": n}`.
    public static func parse(_ json: String) -> BrowserChromiumCookieWriteResult? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let written = object["written"] as? Int, let rejected = object["rejected"] as? Int else { return nil }
        return BrowserChromiumCookieWriteResult(written: written, rejected: rejected)
    }
}
