@testable import CmuxCopyReflow
import Testing

/// Structure preservation (R2, R3, R4, R6) — the failure modes drawn from the
/// PR #4138 review findings.
@Suite
struct ReflowStructureTests {
    private func reflow(_ text: String) -> String {
        ReflowOptions.default.reflow(text)
    }

    @Test func fencedCodePreservedNotMerged() {
        let input = """
        ```
        line one of code
        line two of code that is really quite long and would otherwise merge upward
        more code
        ```
        """ + "\n"
        #expect(reflow(input) == input)
    }

    @Test func decorationNotStrippedInsideFence() {
        let input = "```\n▶ literal arrow stays\n```\n"
        let result = reflow(input)
        #expect(result == input)
        #expect(result.contains("▶ literal arrow stays"))
    }

    @Test func headingIsAHardBreak() {
        let input = "## Summary\nThe files were updated as planned.\n"
        let result = reflow(input)
        #expect(result == input)
        #expect(!result.contains("Summary The"))
    }

    @Test func blockquoteIsAHardBreak() {
        let input = "> quoted text here\nnormal sentence follows on its own line\n"
        let result = reflow(input)
        #expect(result == input)
        #expect(!result.contains("here normal"))
    }

    @Test func tablePreserved() {
        let input = "| a | b |\n|---|---|\n| 1 | 2 |\n"
        #expect(reflow(input) == input)
    }

    @Test func tableAlignmentWhitespacePreserved() {
        let input = "| Name      | Value |\n| Long name | 12    |\n"
        #expect(reflow(input) == input)
    }

    @Test func tableWithoutOuterPipesPreserved() {
        let input = "a | b\n---|---\n1 | 2\n"
        #expect(reflow(input) == input)
    }

    @Test func nestedBulletsPreserved() {
        let input = "- parent item\n  - child item\n"
        #expect(reflow(input) == input)
    }

    @Test func wrappedBulletRejoins() {
        let input = "- a long bullet item that\n  wrapped onto the next line\n"
        #expect(reflow(input) == "- a long bullet item that wrapped onto the next line\n")
    }

    @Test func bareURLWrapJoinsWithoutSpace() {
        let input = "https://example.com/very/long/resource\n/path/continues/here\n"
        #expect(reflow(input) == "https://example.com/very/long/resource/path/continues/here\n")
    }

    @Test func urlBehindListMarkerJoinsWithoutSpace() {
        let input = "- https://example.com/a\n/b/c\n"
        #expect(reflow(input) == "- https://example.com/a/b/c\n")
    }

    @Test func mentionURLJoinsWithSpaceNotConcatenated() {
        let lead = "Refer to https://docs.example.com/guide which explains the entire onboarding flow in"
        let input = "\(lead)\nmore detail.\n"
        let result = reflow(input)
        #expect(result == "\(lead) more detail.\n")
        #expect(result.contains("https://docs.example.com/guide"))
        #expect(!result.contains("in.more"))
    }

    @Test func decorationStrippedAtZeroIndent() {
        #expect(reflow("▶ note here\n") == "note here\n")
    }

    @Test func decorationStrippedAfterIndentRemoval() {
        // Indented decoration: common indent removed first, then the glyph.
        #expect(reflow("    ▶ indented note\n") == "indented note\n")
    }
}
