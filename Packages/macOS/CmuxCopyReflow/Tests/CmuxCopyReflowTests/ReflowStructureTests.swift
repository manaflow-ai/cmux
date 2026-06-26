@testable import CmuxCopyReflow
import XCTest

/// Structure preservation (R2, R3, R4, R6) — the failure modes drawn from the
/// PR #4138 review findings.
final class ReflowStructureTests: XCTestCase {
    func testFencedCodePreservedNotMerged() {
        let input = """
        ```
        line one of code
        line two of code that is really quite long and would otherwise merge upward
        more code
        ```
        """ + "\n"
        XCTAssertEqual(reflowCopiedText(input), input)
    }

    func testDecorationNotStrippedInsideFence() {
        let input = "```\n▶ literal arrow stays\n```\n"
        let result = reflowCopiedText(input)
        XCTAssertEqual(result, input)
        XCTAssertTrue(result.contains("▶ literal arrow stays"))
    }

    func testHeadingIsAHardBreak() {
        let input = "## Summary\nThe files were updated as planned.\n"
        let result = reflowCopiedText(input)
        XCTAssertEqual(result, input)
        XCTAssertFalse(result.contains("Summary The"))
    }

    func testBlockquoteIsAHardBreak() {
        let input = "> quoted text here\nnormal sentence follows on its own line\n"
        let result = reflowCopiedText(input)
        XCTAssertEqual(result, input)
        XCTAssertFalse(result.contains("here normal"))
    }

    func testTablePreserved() {
        let input = "| a | b |\n|---|---|\n| 1 | 2 |\n"
        XCTAssertEqual(reflowCopiedText(input), input)
    }

    func testNestedBulletsPreserved() {
        let input = "- parent item\n  - child item\n"
        XCTAssertEqual(reflowCopiedText(input), input)
    }

    func testWrappedBulletRejoins() {
        let input = "- a long bullet item that\n  wrapped onto the next line\n"
        XCTAssertEqual(
            reflowCopiedText(input),
            "- a long bullet item that wrapped onto the next line\n"
        )
    }

    func testBareURLWrapJoinsWithoutSpace() {
        let input = "https://example.com/very/long/resource\n/path/continues/here\n"
        XCTAssertEqual(
            reflowCopiedText(input),
            "https://example.com/very/long/resource/path/continues/here\n"
        )
    }

    func testURLBehindListMarkerJoinsWithoutSpace() {
        let input = "- https://example.com/a\n/b/c\n"
        XCTAssertEqual(
            reflowCopiedText(input),
            "- https://example.com/a/b/c\n"
        )
    }

    func testMentionURLJoinsWithSpaceNotConcatenated() {
        let lead = "Refer to https://docs.example.com/guide which explains the entire onboarding flow in"
        let input = "\(lead)\nmore detail.\n"
        let result = reflowCopiedText(input)
        XCTAssertEqual(result, "\(lead) more detail.\n")
        XCTAssertTrue(result.contains("https://docs.example.com/guide"))
        XCTAssertFalse(result.contains("in.more"))
    }

    func testDecorationStrippedAtZeroIndent() {
        XCTAssertEqual(reflowCopiedText("▶ note here\n"), "note here\n")
    }

    func testDecorationStrippedAfterIndentRemoval() {
        // Indented decoration: common indent removed first, then the glyph.
        XCTAssertEqual(reflowCopiedText("    ▶ indented note\n"), "indented note\n")
    }
}
