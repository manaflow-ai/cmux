import Foundation

final class RecordingClientConfigURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = ClientConfigRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
        let body = Data("""
        {
          "featureFlags": { "cmux-for-windows": true },
          "featureFlagPayloads": {},
          "errorsWhileComputingFlags": false
        }
        """.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
