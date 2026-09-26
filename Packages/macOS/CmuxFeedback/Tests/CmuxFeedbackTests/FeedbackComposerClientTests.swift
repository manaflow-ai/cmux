import Testing

@testable import CmuxFeedback

@Suite("Feedback composer client")
struct FeedbackComposerClientTests {
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
