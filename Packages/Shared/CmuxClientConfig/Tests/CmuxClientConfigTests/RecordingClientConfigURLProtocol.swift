import Foundation

final class RecordingClientConfigURLProtocol: URLProtocol, @unchecked Sendable {
    enum StubResponse: Sendable {
        case success
        case rateLimited(seconds: Int)
    }

    static let recorder = ClientConfigRequestRecorder()
    private static let responseLock = NSLock()
    nonisolated(unsafe) private static var storedResponse: StubResponse = .success
    static var response: StubResponse {
        get { responseLock.withLock { storedResponse } }
        set { responseLock.withLock { storedResponse = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
        let stub = Self.response
        let statusCode: Int
        let headers: [String: String]
        switch stub {
        case .success:
            statusCode = 200
            headers = ["Content-Type": "application/json"]
        case .rateLimited(let seconds):
            statusCode = 429
            headers = ["Retry-After": String(seconds)]
        }
        let body = Data("""
        {
          "featureFlags": { "cmux-for-windows": true },
          "featureFlagPayloads": {},
          "errorsWhileComputingFlags": false
        }
        """.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
