public import Foundation

/// Which cookie an import wrote, without its value: the name, domain and path
/// that make a cookie one cookie in a jar (RFC 6265 5.3 step 11), so a later
/// Remove can take exactly those cookies back out. The import's audit record
/// keeps these; it never keeps a value.
public struct ImportedCookieIdentity: Sendable, Hashable, Codable {
    /// The cookie's name (`SID`, `__Host-session`).
    public var name: String
    /// RFC 6265 domain: a leading dot for a domain cookie, none for a host-only one.
    public var domain: String
    /// The cookie's path, `/` when the source gave none.
    public var path: String
    /// Whether the cookie is sent only over HTTPS (it picks the URL a removal is checked against).
    public var secure: Bool

    /// Creates an identity from its parts.
    public init(name: String, domain: String, path: String, secure: Bool) {
        self.name = name
        self.domain = domain
        self.path = path.isEmpty ? "/" : path
        self.secure = secure
    }

    /// The identity of `cookie`; its value is not read.
    public init(_ cookie: ImportedCookie) {
        self.init(name: cookie.name, domain: cookie.domain, path: cookie.path, secure: cookie.secure)
    }

    /// The host without a domain cookie's leading dot (`github.com` for `.github.com`).
    public var host: String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }
}
