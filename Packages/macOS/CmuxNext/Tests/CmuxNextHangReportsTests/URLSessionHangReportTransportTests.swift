@testable import CmuxNextHangReports
import Foundation
import Testing

/// The client's answer to each status the server really sends: 204 stored, 400 and 413 dropped
/// for good, 429 and 503 kept for a later try; a plain-http address sends nothing.
struct URLSessionHangReportTransportTests {
    /// Answers every request to `hang-reports.test` with the status in the last path component.
    final class StatusServer: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "hang-reports.test" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url, request.httpMethod == "POST",
                  let response = HTTPURLResponse(url: url, statusCode: Int(url.lastPathComponent) ?? 500, httpVersion: "HTTP/1.1",
                                                 headerFields: [:]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// Answers 204 only when the request carries exactly the fixed headers (no cookie, the fixed
    /// language and user agent), else 400.
    final class HeaderServer: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "hang-headers.test" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let headers = request.allHTTPHeaderFields ?? [:]
            let fixed = URLSessionHangReportTransport.fixedHeaders.allSatisfy { headers[$0.key] == $0.value }
            let ok = fixed && headers["Cookie"] == nil && headers["Authorization"] == nil
                && headers["Content-Type"] == "application/json"
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: ok ? 204 : 400, httpVersion: "HTTP/1.1", headerFields: [:]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test func aRequestCarriesOnlyTheFixedHeadersNotThePersonsLanguages() async {
        #expect(URLSessionHangReportTransport.fixedHeaders["Accept-Language"] == "en")
        let transport = URLSessionHangReportTransport(endpoint: "https://hang-headers.test/api/hang-reports",
                                                      protocolClasses: [HeaderServer.self])
        #expect(await transport.send(Data("{}".utf8)) == .accepted)
    }

    @Test(arguments: zip([204, 400, 413, 429, 503],
                         [HangReportTransportResult.accepted, .refused(status: 400), .refused(status: 413), .retryLater, .retryLater]))
    func eachStatusMapsToItsOutboxAction(status: Int, expected: HangReportTransportResult) async {
        let transport = URLSessionHangReportTransport(endpoint: "https://hang-reports.test/api/\(status)",
                                                      protocolClasses: [StatusServer.self])
        #expect(await transport.send(Data("{}".utf8)) == expected)
    }

    @Test func aRedirectIsKeptForLaterNotFollowed() {
        #expect(URLSessionHangReportTransport.result(status: 307) == .retryLater)
        #expect(URLSessionHangReportTransport.result(status: 308) == .retryLater)
    }

    @Test func aPlainHTTPAddressSendsNothing() async {
        let transport = URLSessionHangReportTransport(endpoint: "http://cmux.com/api/hang-reports")
        #expect(transport.endpoint == nil)
        #expect(await transport.send(Data("{}".utf8)) == .refused(status: 0))
    }
}
