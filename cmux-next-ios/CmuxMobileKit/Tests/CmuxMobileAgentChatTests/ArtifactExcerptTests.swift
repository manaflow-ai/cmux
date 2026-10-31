import CmuxMobileArtifacts
import Testing

/// SPEC 19: code and text tiles show their first lines.
@Suite struct ArtifactExcerptTests {
    @Test func keepsTheFirstTwelveLinesAndDropsTrailingBlanks() {
        let text = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = TerminalArtifact.thumbnailExcerpt(text)
        #expect(excerpt?.split(separator: "\n").count == 12)
        #expect(TerminalArtifact.thumbnailExcerpt("a\n\n  \n") == "a")
        #expect(TerminalArtifact.thumbnailExcerpt("\n \n") == nil)
        #expect(TerminalArtifact.thumbnailExcerpt("\tx") == "    x")
    }
}
