import Foundation

/// A parsed HTTP/1.1 request from the cmux control transport.
///
/// Produced by ``HTTPRequestParser``; the parser lowercases header
/// names so callers can use ``header(_:)`` case-insensitively without
/// re-walking the array. Query parameters are percent-decoded once at
/// parse time.
public struct HTTPRequest: Sendable, Equatable {
    /// HTTP method token from the request line (e.g. `GET`, `POST`).
    /// Preserved verbatim so router 405 responses can echo what the
    /// client sent.
    public let method: String

    /// Request-target path with the query string stripped (e.g.
    /// `/v1/surfaces`).
    public let path: String

    /// Percent-decoded query parameters keyed by name. Duplicate keys
    /// resolve to the last value seen.
    public let query: [String: String]

    /// Headers in the order received, with names lowercased per RFC
    /// 7230 §3.2 case-insensitivity rules.
    public let headers: [(String, String)]

    /// Request body bytes; empty when there was no `Content-Length`
    /// or the body was zero-length.
    public let body: Data

    /// Creates a request value. Tests use this directly; production
    /// callers go through ``HTTPRequestParser``.
    public init(
        method: String,
        path: String,
        query: [String: String],
        headers: [(String, String)],
        body: Data
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Returns the first header value for `name`, matched
    /// case-insensitively.
    ///
    /// - Parameter name: Header field name; matched against the
    ///   already-lowercased stored names.
    /// - Returns: The first matching value, or `nil` if absent.
    public func header(_ name: String) -> String? {
        let key = name.lowercased()
        return headers.first { $0.0 == key }?.1
    }

    public static func == (lhs: HTTPRequest, rhs: HTTPRequest) -> Bool {
        guard
            lhs.method == rhs.method,
            lhs.path == rhs.path,
            lhs.query == rhs.query,
            lhs.body == rhs.body,
            lhs.headers.count == rhs.headers.count
        else { return false }
        for (l, r) in zip(lhs.headers, rhs.headers) where l != r {
            return false
        }
        return true
    }
}
