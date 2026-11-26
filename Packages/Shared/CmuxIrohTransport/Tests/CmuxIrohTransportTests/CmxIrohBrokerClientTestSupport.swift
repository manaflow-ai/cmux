import Foundation
@testable import CmuxIrohTransport

final class BrokerRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var destination: URL?
    nonisolated(unsafe) private static var captured: [URLRequest] = []

    static func reset(destination: URL) {
        lock.lock()
        self.destination = destination
        captured.removeAll()
        lock.unlock()
    }

    static func capturedDestinationRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool {
        ["cmux.example", "attacker.example"].contains(request.url?.host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.path == "/capture" {
            Self.lock.lock()
            Self.captured.append(request)
            Self.lock.unlock()
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        Self.lock.lock()
        let destination = Self.destination
        Self.lock.unlock()
        guard let destination else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var redirected = request
        redirected.url = destination
        let response = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": destination.absoluteString]
        )!
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
    }

    override func stopLoading() {}
}

actor RecordingBrokerTransport: CmxIrohHTTPTransport {
    struct Response: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]

        static func json(
            status: Int,
            body: String,
            headers: [String: String] = [:]
        ) -> Self {
            Self(status: status, body: Data(body.utf8), headers: headers)
        }
    }

    private var pending: [Response]
    private var captured: [URLRequest] = []
    private let failure: URLError.Code?

    init(responses: [Response], failure: URLError.Code? = nil) {
        pending = responses
        self.failure = failure
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        captured.append(request)
        if let failure { throw URLError(failure) }
        let response = pending.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
                .merging(response.headers) { _, new in new }
        )!
        return (response.body, http)
    }

    func requests() -> [URLRequest] { captured }
}
