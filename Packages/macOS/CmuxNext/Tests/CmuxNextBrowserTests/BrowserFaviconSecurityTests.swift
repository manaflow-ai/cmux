import Foundation
import Testing
@testable import CmuxNextBrowser
import CmuxNextRemoteFetch

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

    @Test func aNameThatResolvesPrivatelyIsRefusedBeforeConnect() async throws {
        let transport = FaviconTransportProbe(response: .init(status: 200, headers: [:], body: Data()))
        let loader = BrowserFaviconLoader(
            resolver: FixedFaviconResolver(addresses: [.v4([10, 0, 0, 7])]),
            transport: transport
        )

        let icon = await loader.favicon(
            at: try #require(URL(string: "https://public-looking.invalid/icon.png")),
            profile: .default
        )

        #expect(icon == nil)
        #expect(transport.requestCount == 0, "the favicon fetch connected after DNS resolved privately")
    }

    @Test func aRedirectToLoopbackIsRefusedBeforeTheSecondRequest() async throws {
        let transport = FaviconTransportProbe(response: .init(
            status: 302, headers: ["location": "https://127.0.0.1/private"], body: Data()
        ))
        let loader = BrowserFaviconLoader(
            resolver: FixedFaviconResolver(addresses: [.v4([1, 1, 1, 1])]),
            transport: transport
        )

        let icon = await loader.favicon(
            at: try #require(URL(string: "https://public.example/icon.png")),
            profile: .default
        )

        #expect(icon == nil)
        #expect(transport.requestCount == 1, "the favicon fetch followed a redirect to loopback")
    }
}

private nonisolated struct FixedFaviconResolver: RemoteAddressResolving {
    let addresses: [RemoteAddress]
    func resolve(_ host: String) async throws -> [RemoteAddress] { addresses }
}

/// A deterministic guarded-fetch transport. The lock protects the request count across tasks.
private nonisolated final class FaviconTransportProbe: RemoteFetchTransport, @unchecked Sendable {
    private let response: RemoteFetchResponse
    private let lock = NSLock()
    private var count = 0

    init(response: RemoteFetchResponse) { self.response = response }
    var requestCount: Int { lock.withLock { count } }

    func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse {
        lock.withLock { count += 1 }
        return response
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
