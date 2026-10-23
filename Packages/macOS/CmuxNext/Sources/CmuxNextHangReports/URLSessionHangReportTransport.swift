public import Foundation

/// Posts report bodies with an ephemeral session: no cookies, no cache, no credentials, a fixed
/// user agent, 30 s timeout.
public nonisolated struct URLSessionHangReportTransport: HangReportTransport {
    /// The production endpoint.
    public static let defaultEndpoint = "https://cmux.com/api/hang-reports"
    public static let userAgent = "cmux-hang-reports/1"

    /// Where reports go; nil (an address that does not parse) sends nothing.
    public let endpoint: URL?
    private let session: URLSession

    public init(endpoint: String = URLSessionHangReportTransport.defaultEndpoint) {
        self.endpoint = URL(string: endpoint).flatMap { $0.scheme == "https" || $0.host == "localhost" ? $0 : nil }
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
        guard let endpoint else { return .refused(status: 0) }
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
