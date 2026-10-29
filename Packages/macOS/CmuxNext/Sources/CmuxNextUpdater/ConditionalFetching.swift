public import Foundation

/// A GET that may answer "not modified" (`If-None-Match`, RFC 9110 13.1.2). A seam so tests serve fixture files.
nonisolated public protocol ConditionalFetching: Sendable {
    /// `etag` nil sends no `If-None-Match`; a 304 answers ``ConditionalFetchResult/notModified``.
    func fetch(_ url: URL, ifNoneMatch etag: String?) async throws(ConditionalFetchError) -> ConditionalFetchResult
}

/// What a conditional GET returned.
nonisolated public enum ConditionalFetchResult: Sendable, Equatable {
    case notModified
    case fetched(Data, etag: String?)
}

/// Why a conditional GET returned no answer.
nonisolated public enum ConditionalFetchError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The server answered with a status outside 2xx and 304 (404: the feed publishes no such file).
    case http(status: Int)
    /// The request did not complete: the `URLError.Code` raw value (offline, timeout, TLS, cancelled).
    case network(code: Int)

    public var description: String {
        switch self {
        case .http(let status): "HTTP \(status)"
        case .network(let code): "network error \(code)"
        }
    }
}
