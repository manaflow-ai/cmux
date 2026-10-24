public import Foundation

/// One cookie of a tab's profile, as automation reads and writes it.
public nonisolated struct BrowserCookie: Sendable, Hashable {
    public var name: String
    public var value: String
    /// A leading dot makes a domain cookie; without one it is host-only.
    public var domain: String
    public var path: String
    /// Nil for a session cookie.
    public var expires: Date?
    public var secure: Bool
    public var httpOnly: Bool

    public init(name: String, value: String, domain: String, path: String, expires: Date?, secure: Bool, httpOnly: Bool) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
    }
}
