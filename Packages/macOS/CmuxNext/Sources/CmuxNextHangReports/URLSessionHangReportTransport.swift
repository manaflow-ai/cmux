public import Foundation

/// Posts report bodies with an ephemeral session: no cookies, no cache, no credentials, a fixed
/// user agent, 30 s timeout.
public nonisolated struct URLSessionHangReportTransport: HangReportTransport {
    /// The production endpoint.
    public static let defaultEndpoint = URL(string: "https://cmux.com/api/hang-reports")!
    public static let userAgent = "cmux-hang-reports/1"

    public let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL = URLSessionHangReportTransport.defaultEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: configuration)
    }

    public func send(_ body: Data) async -> HangReportTransportResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            return .retryLater
        }
        switch http.statusCode {
        case 200..<300: return .accepted
        case 400, 413, 422: return .refused(status: http.statusCode)
        default: return .retryLater
        }
    }
}
