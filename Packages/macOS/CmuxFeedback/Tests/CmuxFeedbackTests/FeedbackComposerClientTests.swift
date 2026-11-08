import Foundation
import Testing

@testable import CmuxFeedback

@Suite("Feedback composer client")
struct FeedbackComposerClientTests {
    @Test("submitted multipart body keeps hostile filenames inside the attachment header")
    func submittedMultipartFileNameStripsControlCharacters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("capture\"\r\nX-Injected: yes\u{0001}\t\u{007F}.png")
        try Data("attachment-payload".utf8).write(to: file)

        try #require(URLProtocol.registerClass(FeedbackMultipartCaptureProtocol.self))
        defer { URLProtocol.unregisterClass(FeedbackMultipartCaptureProtocol.self) }
        let settings = FeedbackComposerSettings(
            endpointEnvironmentKey: UUID().uuidString,
            defaultEndpoint: "https://feedback-multipart-test.invalid/upload"
        )
        try await FeedbackComposerClient(settings: settings).submit(
            email: "test@example.com",
            message: "Multipart regression",
            attachments: [try FeedbackComposerAttachment(url: file)]
        )

        let captured = try #require(FeedbackMultipartCaptureProtocol.capturedRequest())
        let contentType = try #require(captured.request.value(forHTTPHeaderField: "Content-Type"))
        let prefix = "multipart/form-data; boundary="
        try #require(contentType.hasPrefix(prefix))
        let boundary = String(contentType.dropFirst(prefix.count))
        let body = String(decoding: captured.body, as: UTF8.self)
        let parts = body.components(separatedBy: "--\(boundary)")
        #expect(captured.request.httpMethod == "POST")
        #expect(parts.first == "")
        #expect(parts.last == "--\r\n")
        #expect(parts.filter { $0.contains("name=\"attachments\"") } == [
            "\r\nContent-Disposition: form-data; name=\"attachments\"; filename=\"captureX-Injected: yes.png\"\r\n"
                + "Content-Type: image/png\r\n\r\nattachment-payload\r\n",
        ])
        #expect(!body.contains("\r\nX-Injected:"))
    }

    @Test("multipart filenames drop quotes and control characters")
    func multipartFileNameStripsQuotesAndControlCharacters() {
        let unsafeFileName = "capture\"\r\ninjected\u{0001}\t\u{007F}.png"
        #expect(FeedbackComposerClient.multipartFileName(unsafeFileName) == "captureinjected.png")
    }

    @Test("ordinary filenames pass through unchanged")
    func multipartFileNameKeepsOrdinaryNames() {
        #expect(FeedbackComposerClient.multipartFileName("Screen Shot 2026-09-25 at 10.00.00.png") == "Screen Shot 2026-09-25 at 10.00.00.png")
        #expect(FeedbackComposerClient.multipartFileName("日本語.png") == "日本語.png")
    }
}

private final class FeedbackMultipartCaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: (request: URLRequest, body: Data)?

    static func capturedRequest() -> (request: URLRequest, body: Data)? {
        lock.withLock { captured }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "feedback-multipart-test.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 {
                    client?.urlProtocol(self, didFailWithError: stream.streamError ?? URLError(.cannotDecodeRawData))
                    return
                }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.withLock { Self.captured = (request, body) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
