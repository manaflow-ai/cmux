import Foundation
import Testing
@testable import CmuxNextBrowser

@MainActor
@Suite(.serialized) struct BrowserFaviconSecurityTests {
    @Test func aLoopbackIconIsRefusedBeforeAnyRequest() async throws {
        FaviconNetworkProbe.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FaviconNetworkProbe.self]
        let loader = BrowserFaviconLoader(session: URLSession(configuration: configuration))

        let icon = await loader.favicon(
            at: try #require(URL(string: "http://127.0.0.1/private-state-changing-get")),
            profile: .default
        )

        #expect(icon == nil)
        #expect(FaviconNetworkProbe.requestCount == 0, "a page-selected favicon reached loopback")
    }
}

/// A no-network URLSession probe. Serialized test access plus the lock protects its shared count.
private nonisolated final class FaviconNetworkProbe: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var count = 0
    private static let lock = NSLock()

    static var requestCount: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
