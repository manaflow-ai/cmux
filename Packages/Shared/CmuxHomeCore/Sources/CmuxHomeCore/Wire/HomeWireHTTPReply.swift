public import Foundation

/// A status and body from a `cmux.wire/1` server.
public struct HomeWireHTTPReply: Sendable, Hashable {
    public var status: Int
    public var body: Data
    /// The `Retry-After` header in seconds, when the server sent one.
    public var retryAfter: TimeInterval?
    /// The `ETag` header, when the server sent one (a direct R2 part PUT answers its part's etag here).
    public var etag: String?

    public init(status: Int, body: Data, retryAfter: TimeInterval? = nil, etag: String? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
        self.etag = etag
    }

    /// A reply whose body is `json`.
    public init(status: Int = 200, json: HomeWireJSON, retryAfter: TimeInterval? = nil) {
        self.init(status: status, body: json.data, retryAfter: retryAfter)
    }
}
