import Foundation
import Testing
@testable import CmuxSubrouter

/// URLProtocol fixture that offers one redirect and records every request.
/// The redirect target returns a valid health payload so the test would pass
/// if URLSession followed the hop and leaked the admin header.
final class RedirectingSubrouterURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset() {
        lock.withLock { requests = [] }
    }

    static func capturedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "source.example" || request.url?.host == "redirect.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests.append(request) }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.host == "source.example" {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://redirect.example/_subrouter/health"]
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: URL(string: "https://redirect.example/_subrouter/health")!),
                redirectResponse: response
            )
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct SubrouterHTTPClientTests {
    @Test func adminTokenIsNeverSentAcrossRedirect() async throws {
        RedirectingSubrouterURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingSubrouterURLProtocol.self]
        let client = SubrouterHTTPClient(requestTimeout: 2, configuration: configuration)
        let endpoint = SubrouterEndpoint(
            baseURL: URL(string: "https://source.example")!,
            adminToken: "secret-admin-token"
        )

        await #expect(throws: SubrouterClientError.self) {
            _ = try await client.health(endpoint: endpoint)
        }

        let requests = RedirectingSubrouterURLProtocol.capturedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].value(forHTTPHeaderField: "X-Subrouter-Admin-Token") == "secret-admin-token")
    }
}
