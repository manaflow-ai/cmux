public import Foundation

/// URLSession-backed connector HTTP client.
public struct URLSessionInboxHTTPClient: InboxHTTPClient {
    /// Creates a URLSession transport.
    public init() {}

    /// Performs a request using `URLSession.shared`.
    public func data(for request: URLRequest) async throws -> InboxHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let headers = http?.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String else { return }
            result[key] = String(describing: pair.value)
        } ?? [:]
        return InboxHTTPResponse(statusCode: http?.statusCode ?? 0, headers: headers, data: data)
    }
}
