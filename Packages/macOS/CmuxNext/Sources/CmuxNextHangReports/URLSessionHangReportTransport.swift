public import Foundation

/// Posts report bodies with an ephemeral session: no cookies, no cache, no credentials, fixed
/// headers (``fixedHeaders``: the user agent, and `Accept-Language: en` instead of the person's
/// language list, which URLSession would add by itself), 30 s timeout, and no redirects (a 3xx answer is kept for a later try; the body is
/// never posted to another address).
public nonisolated struct URLSessionHangReportTransport: HangReportTransport {
    /// The production endpoint.
    public static let defaultEndpoint = "https://cmux.com/api/hang-reports"
    /// The fixed user agent of every request.
    public static let userAgent = "cmux-hang-reports/1"
    /// The headers every request carries besides `Content-Type`, set on the request itself so
    /// none of URLSession's own defaults (the preferred languages) is sent in their place.
    public static let fixedHeaders = ["User-Agent": userAgent, "Accept-Language": "en", "Accept": "*/*"]

    /// Where reports go; nil (an address that does not parse) sends nothing.
    public let endpoint: URL?
    private let session: URLSession

    /// Makes the value from its parts.
    public init(endpoint: String = URLSessionHangReportTransport.defaultEndpoint) {
        self.init(endpoint: endpoint, protocolClasses: [])
    }

    /// - Parameter protocolClasses: `URLProtocol` classes tried before the system's (tests pass a
    ///   fake server).
    init(endpoint: String, protocolClasses: [AnyClass]) {
        self.endpoint = URL(string: endpoint).flatMap { $0.scheme == "https" || $0.host == "localhost" ? $0 : nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = Self.fixedHeaders
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? []) }
        session = URLSession(configuration: configuration)
    }

    /// Posts one body; see ``HangReportTransportResult``.
    public func send(_ body: Data) async -> HangReportTransportResult {
        guard let endpoint else { return .refused(status: 0) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        for (name, value) in Self.fixedHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (_, response) = try? await session.data(for: request, delegate: NoRedirects()),
              let http = response as? HTTPURLResponse else {
            return .retryLater
        }
        return Self.result(status: http.statusCode)
    }

    /// What a status means: 2xx stored, 400/413/422 refused for good, anything else (429, 5xx, a
    /// refused redirect) later.
    static func result(status: Int) -> HangReportTransportResult {
        switch status {
        case 200..<300: .accepted
        case 400, 413, 422: .refused(status: status)
        default: .retryLater
        }
    }
}

/// Refuses every redirect, so the 3xx answer itself comes back. The selector is spelled out: an
/// optional requirement whose Swift signature drifts between SDKs would otherwise stop matching
/// silently, and the redirect would be followed.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    @objc(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
