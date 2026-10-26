public import Foundation

/// Conditional GETs over an ephemeral `URLSession` with a hard deadline and no
/// local cache, as ``URLSessionAppcastFetcher``: the server's ETag decides.
nonisolated public struct URLSessionConditionalFetcher: ConditionalFetching {
    private let session: URLSession

    public init(deadline: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = deadline
        configuration.timeoutIntervalForResource = deadline
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func fetch(_ url: URL, ifNoneMatch etag: String?) async throws(ConditionalFetchError) -> ConditionalFetchResult {
        var request = URLRequest(url: url)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw .network(code: error.code.rawValue)
        } catch {
            throw .network(code: URLError.Code.unknown.rawValue)
        }
        guard let http = response as? HTTPURLResponse else { return .fetched(data, etag: nil) }
        if http.statusCode == 304 { return .notModified }
        guard (200..<300).contains(http.statusCode) else { throw .http(status: http.statusCode) }
        return .fetched(data, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}
