public import Foundation

/// A conditional GET's answer.
nonisolated public enum ConditionalResponse: Equatable, Sendable {
    /// 304: the file is the one the ETag names.
    case notModified
    case changed(Data, etag: String?)
}

/// Fetches with `If-None-Match`. A seam so tests answer without the network.
nonisolated public protocol ConditionalFetching: Sendable {
    func fetch(_ url: URL, etag: String?) async throws -> ConditionalResponse
}

/// Over an ephemeral `URLSession` with a hard deadline and no local cache, so a 304 comes from
/// the server's ETag, not a cached copy.
nonisolated public struct URLSessionConditionalFetcher: ConditionalFetching {
    private let session: URLSession

    public init(deadline: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = deadline
        configuration.timeoutIntervalForResource = deadline
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func fetch(_ url: URL, etag: String?) async throws -> ConditionalResponse {
        var request = URLRequest(url: url)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return .changed(data, etag: nil) }
        if http.statusCode == 304 { return .notModified }
        guard (200..<300).contains(http.statusCode) else {
            throw AppcastParseError(message: "\(url.lastPathComponent) returned HTTP \(http.statusCode)")
        }
        return .changed(data, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}
