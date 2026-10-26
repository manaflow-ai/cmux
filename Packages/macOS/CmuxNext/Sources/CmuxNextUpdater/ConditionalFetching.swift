public import Foundation

/// A GET that may answer "not modified" (`If-None-Match`, RFC 9110 13.1.2). A seam so tests serve fixture files.
nonisolated public protocol ConditionalFetching: Sendable {
    /// `etag` nil sends no `If-None-Match`; a 304 answers ``ConditionalFetchResult/notModified``.
    func fetch(_ url: URL, ifNoneMatch etag: String?) async throws -> ConditionalFetchResult
}

/// What a conditional GET returned.
nonisolated public enum ConditionalFetchResult: Sendable, Equatable {
    case notModified
    case fetched(Data, etag: String?)
}

/// A conditional GET the server refused.
nonisolated public enum ConditionalFetchError: Error, Sendable, Equatable {
    /// A status outside 2xx and 304 (404: the feed publishes no such file).
    case http(status: Int)
}
