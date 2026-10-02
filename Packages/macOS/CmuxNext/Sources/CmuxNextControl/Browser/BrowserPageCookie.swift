public import CmuxNextSettings
import Foundation

/// One cookie of a tab's profile, engine-neutral.
public struct BrowserPageCookie: Sendable, Hashable {
    public var name: String
    public var value: String
    /// A leading dot makes a domain cookie; without one it is host-only.
    public var domain: String
    public var path: String
    /// Unix seconds; nil for a session cookie.
    public var expires: Double?
    public var secure: Bool
    public var httpOnly: Bool

    public init(name: String, value: String, domain: String, path: String = "/", expires: Double? = nil,
                secure: Bool = false, httpOnly: Bool = false) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
    }

    public var hostOnly: Bool { !domain.hasPrefix(".") }

    /// The domain without a domain cookie's leading dot, lowercased.
    var host: String { (domain.hasPrefix(".") ? String(domain.dropFirst()) : domain).lowercased() }

    /// The old `cmux browser cookies` shape (`hostOnly`, `httpOnly`, `session_only`).
    public var json: JSONValue {
        ["name": .string(name), "value": .string(value), "domain": .string(domain), "hostOnly": .bool(hostOnly),
         "path": .string(path), "secure": .bool(secure), "httpOnly": .bool(httpOnly), "session_only": .bool(expires == nil),
         "expires": expires.map { .number($0.rounded(.down)) } ?? .null]
    }

    /// Reads what an engine returns (`json`'s keys).
    public init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, let domain = json["domain"]?.stringValue else { return nil }
        self.init(name: name, value: json["value"]?.stringValue ?? "", domain: domain, path: json["path"]?.stringValue ?? "/",
                  expires: json["expires"]?.doubleValue, secure: json["secure"]?.boolValue ?? false,
                  httpOnly: json["httpOnly"]?.boolValue ?? json["http_only"]?.boolValue ?? false)
    }

    /// Whether a request to `url` would carry this cookie (RFC 6265 domain
    /// and path match; a secure cookie needs https; an expired one never).
    func isSent(to url: URL, now: Date) -> Bool {
        guard let requestHost = url.host?.lowercased() else { return false }
        if let expires, expires <= now.timeIntervalSince1970 { return false }
        if secure, url.scheme?.lowercased() != "https" { return false }
        let domainMatch = requestHost == host || (!hostOnly && requestHost.hasSuffix("." + host))
        // Percent-encoded and with its trailing slash, as the request sends it.
        let encoded = url.path(percentEncoded: true)
        let requestPath = encoded.isEmpty ? "/" : encoded
        let pathMatch = requestPath == path || (requestPath.hasPrefix(path) && (path.hasSuffix("/") || requestPath.dropFirst(path.count).hasPrefix("/")))
        return domainMatch && pathMatch
    }

    /// Whether the cookie belongs to `domain` or one of its subdomains
    /// (dots and case ignored), as the old `cookies clear --domain` matched.
    func isIn(domain other: String) -> Bool {
        let other = other.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return !other.isEmpty && (host == other || host.hasSuffix("." + other))
    }
}

/// What `BrowserPageOperation.cookies` does.
public enum BrowserPageCookieRequest: Sendable, Hashable {
    case list
    case set([BrowserPageCookie])
    /// Deletes cookies matching each one's name, domain and path.
    case delete([BrowserPageCookie])
}
