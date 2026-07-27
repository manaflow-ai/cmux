import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact Markdown presentation")
struct ChatArtifactMarkdownPresentationTests {
    @Test("small files toggle between rendered and raw")
    func togglesSmallFile() {
        var presentation = ChatArtifactMarkdownPresentation(byteCount: 1_500_000)

        #expect(presentation.isRenderedAvailable)
        #expect(presentation.mode == .rendered)
        presentation.select(.raw)
        #expect(presentation.mode == .raw)
        presentation.select(.rendered)
        #expect(presentation.mode == .rendered)
    }

    @Test("oversize files remain raw")
    func oversizeFallsBackToRaw() {
        var presentation = ChatArtifactMarkdownPresentation(byteCount: 1_500_001)

        #expect(!presentation.isRenderedAvailable)
        #expect(presentation.mode == .raw)
        presentation.select(.rendered)
        #expect(presentation.mode == .raw)
    }
}
