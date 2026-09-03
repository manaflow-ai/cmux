import Foundation

/// Foundation constructs URLProtocol instances on loader threads; this test
/// protocol has no mutable instance state.
final class FeedbackComposerRecordingURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = FeedbackComposerRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cmux-feedback-test.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let capturedRequest = CapturedFeedbackRequest(body: bodyData(for: request))
        Task { await Self.recorder.record(capturedRequest) }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func bodyData(for request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
