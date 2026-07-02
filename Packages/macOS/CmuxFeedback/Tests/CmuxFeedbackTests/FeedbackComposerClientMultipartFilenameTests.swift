import Foundation
import Testing

@testable import CmuxFeedback

private struct CapturedFeedbackRequest: Sendable {
    let body: Data
}

actor FeedbackComposerRequestRecorder {
    private var requests: [CapturedFeedbackRequest] = []
    private var continuations: [CheckedContinuation<CapturedFeedbackRequest, Never>] = []

    fileprivate func record(_ request: CapturedFeedbackRequest) {
        if continuations.isEmpty {
            requests.append(request)
        } else {
            continuations.removeFirst().resume(returning: request)
        }
    }

    fileprivate func nextRequest() async -> CapturedFeedbackRequest {
        if requests.isEmpty == false {
            return requests.removeFirst()
        }

        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func reset() {
        requests.removeAll()
    }
}

/// Foundation constructs URLProtocol instances on loader threads; this test
/// protocol has no mutable instance state.
private final class FeedbackComposerRecordingURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = FeedbackComposerRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cmux-feedback-test.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let capturedRequest = CapturedFeedbackRequest(body: Self.bodyData(for: request))
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

    private static func bodyData(for request: URLRequest) -> Data {
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

@Suite("Feedback composer multipart filenames", .serialized)
struct FeedbackComposerClientMultipartFilenameTests {
    @Test func attachmentFilenameStripsHeaderBreakingCharacters() async throws {
        await FeedbackComposerRecordingURLProtocol.recorder.reset()
        URLProtocol.registerClass(FeedbackComposerRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(FeedbackComposerRecordingURLProtocol.self) }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-feedback-client-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let fileURL = scratch.appendingPathComponent("screen\"shot\r\nX-Injected: yes.png")
        try Data("fake png data".utf8).write(to: fileURL)

        let client = FeedbackComposerClient(
            settings: FeedbackComposerSettings(
                defaultEndpoint: "http://cmux-feedback-test.invalid/api/feedback"
            )
        )

        try await client.submit(
            email: "valid@example.com",
            message: "Multipart filename regression",
            attachments: [try FeedbackComposerAttachment(url: fileURL)]
        )

        let request = await FeedbackComposerRecordingURLProtocol.recorder.nextRequest()
        let body = try #require(String(data: request.body, encoding: .utf8))

        #expect(body.contains(#"filename="screenshotX-Injected: yes.png""#))
        #expect(!body.contains("filename=\"screenshot\r\nX-Injected: yes.png\""))
        #expect(!body.contains("\r\nX-Injected: yes.png\"\r\n"))
    }

    @Test func attachmentFilenameStripsBackslashes() async throws {
        await FeedbackComposerRecordingURLProtocol.recorder.reset()
        URLProtocol.registerClass(FeedbackComposerRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(FeedbackComposerRecordingURLProtocol.self) }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-feedback-client-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Backslash is the quoted-string escape character in a multipart
        // Content-Disposition `filename="..."` parameter, so a raw backslash
        // (especially one adjacent to the closing quote) would escape that quote
        // and break the header. The sanitizer must remove every backslash.
        let fileURL = scratch.appendingPathComponent(#"re\po\rt\.png"#)
        try Data("fake png data".utf8).write(to: fileURL)

        let client = FeedbackComposerClient(
            settings: FeedbackComposerSettings(
                defaultEndpoint: "http://cmux-feedback-test.invalid/api/feedback"
            )
        )

        try await client.submit(
            email: "valid@example.com",
            message: "Multipart filename backslash regression",
            attachments: [try FeedbackComposerAttachment(url: fileURL)]
        )

        let request = await FeedbackComposerRecordingURLProtocol.recorder.nextRequest()
        let body = try #require(String(data: request.body, encoding: .utf8))

        #expect(body.contains(#"Content-Disposition: form-data; name="attachments"; filename="report.png""#))
        #expect(!body.contains(#"filename="re\po\rt\.png""#))
    }
}
