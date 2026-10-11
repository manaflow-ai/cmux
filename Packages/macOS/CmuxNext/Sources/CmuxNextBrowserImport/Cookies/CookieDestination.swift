public import Foundation

/// Writes imported cookies into a cmux browser profile's cookie store (the
/// App: Chromium's `CefCookieManager` of that profile's request context).
public protocol CookieDestination: Sendable {
    func setCookies(_ cookies: [ImportedCookie], profileID: String) async throws -> CookieWriteResult
}

/// How many cookies the store took; the rest it rejected (an invalid
/// domain for its URL, a `__Host-` prefix rule, a full jar).
public struct CookieWriteResult: Sendable, Equatable, Codable {
    public var written: Int
    public var rejected: Int

    public init(written: Int, rejected: Int) {
        self.written = written
        self.rejected = rejected
    }
}

/// Cookie import results per source profile, counts only.
public struct CookieImportReport: Sendable, Equatable, Codable {
    public var written = 0
    public var rejected = 0
    public var undecryptable = 0
    public var partitioned = 0
    public var expired = 0

    public init(written: Int = 0, rejected: Int = 0, undecryptable: Int = 0, partitioned: Int = 0, expired: Int = 0) {
        self.written = written
        self.rejected = rejected
        self.undecryptable = undecryptable
        self.partitioned = partitioned
        self.expired = expired
    }
}
