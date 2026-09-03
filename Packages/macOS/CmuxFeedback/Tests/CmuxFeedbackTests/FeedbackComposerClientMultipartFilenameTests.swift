import Foundation
import Testing

@testable import CmuxFeedback

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
