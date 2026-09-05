import Foundation
import Testing

@testable import CmuxFeedback

@Suite("Feedback composer client", .serialized)
struct FeedbackComposerClientTests {
    @Test("multipart filenames cannot contain control characters")
    func multipartFilenameStripsControlCharacters() async throws {
        FeedbackComposerURLProtocol.reset()
        let registered = URLProtocol.registerClass(FeedbackComposerURLProtocol.self)
        defer { URLProtocol.unregisterClass(FeedbackComposerURLProtocol.self) }
        #expect(registered)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-feedback-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let unsafeFileName = "capture\"\r\ninjected\u{0001}\t\u{007F}.png"
        let fileURL = temporaryDirectory.appendingPathComponent(unsafeFileName)
        try Data("attachment-data".utf8).write(to: fileURL)
        let attachment = try FeedbackComposerAttachment(url: fileURL)
        #expect(attachment.fileName == unsafeFileName)

        let settings = FeedbackComposerSettings(
            endpointEnvironmentKey: "CMUX_FEEDBACK_CLIENT_TEST_ENDPOINT_\(UUID().uuidString)",
            defaultEndpoint: "https://feedback.test/submit"
        )
        try await FeedbackComposerClient(settings: settings).submit(
            email: "test@example.com",
            message: "multipart filename test",
            attachments: [attachment]
        )

        let body = try #require(FeedbackComposerURLProtocol.capturedBody())
        let bodyString = try #require(String(data: body, encoding: .utf8))
        let markerRange = try #require(bodyString.range(of: #"filename=""#))
        let filenameStart = markerRange.upperBound
        let filenameEnd = try #require(bodyString[filenameStart...].firstIndex(of: "\""))
        let filenameField = bodyString[filenameStart..<filenameEnd]

        #expect(filenameField == "captureinjected.png")
        #expect(filenameField.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        })
    }
}

private final class FeedbackComposerURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var body: Data?

    static func reset() {
        lock.withLock { body = nil }
    }

    static func capturedBody() -> Data? {
        lock.withLock { body }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "feedback.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let requestBody = Self.requestBody(from: request)
        Self.lock.withLock { Self.body = requestBody }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            guard count > 0 else { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
}
