public import Foundation

/// One cookie read from a source browser. Never persisted and never
/// logged: `description`, `debugDescription` and reflection (`dump`,
/// string interpolation, Mirror) hide the value. Cookies pass from the
/// reader to a ``CookieDestination`` in memory; only counts leave the import.
public struct ImportedCookie: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum SameSite: String, Sendable {
        case unspecified, none, lax, strict
    }

    public var name: String
    public var value: String
    /// RFC 6265 domain: a leading dot for a domain cookie ("`.example.com`"),
    /// none for a host-only cookie.
    public var domain: String
    public var path: String
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: SameSite
    /// Nil for a session cookie.
    public var expires: Date?
    public var created: Date?
    public var lastAccess: Date?

    public init(name: String, value: String, domain: String, path: String = "/", secure: Bool = false, httpOnly: Bool = false,
                sameSite: SameSite = .unspecified, expires: Date? = nil, created: Date? = nil, lastAccess: Date? = nil) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path.isEmpty ? "/" : path
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
        self.expires = expires
        self.created = created
        self.lastAccess = lastAccess
    }

    /// The host without a domain cookie's leading dot.
    public var host: String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }

    /// A URL the cookie is valid for (CEF's SetCookie checks the cookie
    /// against it): `https` for secure cookies, else `http`.
    public var url: URL? {
        URL(string: "\(secure ? "https" : "http")://\(host)\(path.hasPrefix("/") ? path : "/" + path)")
    }

    public func isExpired(at now: Date) -> Bool { expires.map { $0 <= now } ?? false }

    public var description: String { "ImportedCookie(\(name) @ \(domain)\(path), value: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["name": name, "domain": domain, "path": path, "value": "<redacted>"], displayStyle: .struct)
    }
}

/// What reading one profile's cookies produced (counts only).
public struct CookieReadResult: Sendable {
    public var cookies: [ImportedCookie]
    /// Rows that could not be decrypted with the source's key.
    public var undecryptable: Int
    /// Partitioned (CHIPS) or container cookies, which CEF cannot store yet.
    public var partitioned: Int
    /// Already expired at read time.
    public var expired: Int

    public init(cookies: [ImportedCookie], undecryptable: Int = 0, partitioned: Int = 0, expired: Int = 0) {
        self.cookies = cookies
        self.undecryptable = undecryptable
        self.partitioned = partitioned
        self.expired = expired
    }
}

/// Why a profile's cookies could not be read at all.
public enum CookieImportError: Error, Equatable, Sendable, Codable {
    /// The Keychain has no "<Name> Safe Storage" item for this browser.
    case keyNotFound(service: String)
    /// The user chose Deny (or cancelled) in macOS's Keychain prompt.
    case keychainDenied(service: String)
    /// The key decrypted nothing: the browser encrypts in a way cmux does not know.
    case undecryptable
    /// The source refuses session data (Tor Browser).
    case refused
    /// Full Disk Access is needed (Safari).
    case needsFullDiskAccess
    /// The file is not in the expected format.
    case malformed(String)
    /// cmux's cookie store could not start (Chromium is not available).
    case storeUnavailable
}
