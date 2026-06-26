@testable import CmuxCopyReflow
import XCTest

/// Paragraph join/keep behavior, including the conservative-join guards (R1,
/// R5, R11).
final class ReflowParagraphTests: XCTestCase {
    func testUniformIndentWrappedProseJoins() {
        // The reported real-world symptom: every line shares a 2-space indent and
        // the wrap is at viewport width (no extra continuation indent). The
        // full-width signal must still rejoin it.
        let long = "The quick brown fox jumps over the lazy dog and keeps running across the whole field today"
        let input = "  \(long)\n  and then it stops.\n"
        let expected = "\(long) and then it stops.\n"
        XCTAssertEqual(reflowCopiedText(input), expected)
    }

    func testSingleWordContinuationJoinsWithSpace() {
        // A single-word continuation must join with a space, never "Helloworld".
        let input = "A short lead ending in Hello\n  world\n"
        let result = reflowCopiedText(input)
        XCTAssertEqual(result, "A short lead ending in Hello world\n")
        XCTAssertFalse(result.contains("Helloworld"))
    }

    func testUnindentedShortLinesNotJoined() {
        // No indent signal, below min width -> left alone.
        let input = "alpha\nbeta\ngamma\n"
        XCTAssertEqual(reflowCopiedText(input), input)
    }

    func testShortFilePathsNotJoined() {
        let input = "/usr/local/bin/alpha\n/opt/homebrew/bin/beta\n/var/log/system.log\n"
        XCTAssertEqual(reflowCopiedText(input), input)
    }

    func testLongFilePathsNotJoined() {
        // Long enough to clear minWidth, but single tokens (no spaces) so the
        // space guard keeps them apart.
        let input =
            "/Users/example/Library/ApplicationSupport/cmux/deep/path/alpha_file_name\n"
            + "/Users/example/Library/ApplicationSupport/cmux/deep/path/beta_file_name_x\n"
            + "/Users/example/Library/ApplicationSupport/cmux/deep/path/gamma_file_name\n"
        XCTAssertEqual(reflowCopiedText(input), input)
    }

    func testTwoSentencesNotJoined() {
        // Sentence terminator is a hard boundary even when both lines are prose.
        let input = "This is the first sentence here.\nThis is the second sentence here.\n"
        XCTAssertEqual(reflowCopiedText(input), input)
    }

    func testIndentSignalDecidesTheJoin() {
        // Same text: with a continuation indent it joins; without it, it does not.
        let withIndent = "Lead line goes here\n  continues on this line\n"
        XCTAssertEqual(
            reflowCopiedText(withIndent),
            "Lead line goes here continues on this line\n"
        )

        let withoutIndent = "Lead line goes here\ncontinues on this line\n"
        XCTAssertEqual(reflowCopiedText(withoutIndent), withoutIndent)
    }

    func testBlankLinesPreservedAsParagraphBoundaries() {
        let input = "first paragraph stands on its own here\n\nsecond paragraph also alone\n"
        XCTAssertEqual(reflowCopiedText(input), input)
    }

    func testIdempotentOnCleanProse() {
        let input = "first paragraph stands on its own here\n\nsecond paragraph also alone\n"
        let once = reflowCopiedText(input)
        XCTAssertEqual(reflowCopiedText(once), once)
    }

    func testIdempotentAfterReflow() {
        let long = "The quick brown fox jumps over the lazy dog and keeps running across the whole field today"
        let input = "  \(long)\n  and then it stops.\n"
        let once = reflowCopiedText(input)
        XCTAssertEqual(reflowCopiedText(once), once)
    }

    func testTrailingNewlinePreserved() {
        XCTAssertEqual(reflowCopiedText("hello world"), "hello world")
        XCTAssertTrue(reflowCopiedText("hello world\n").hasSuffix("\n"))
    }

    func testEmptyInput() {
        XCTAssertEqual(reflowCopiedText(""), "")
    }

    func testCommonIndentStrippedWhenNotJoining() {
        let input = "    alpha\n    beta\n"
        XCTAssertEqual(reflowCopiedText(input), "alpha\nbeta\n")
    }

    /// The shape of the originally reported paste: multiple paragraphs, every
    /// line sharing a 2-space indent, wrapped at viewport width, separated by a
    /// truly blank line. Each paragraph should collapse to one clean line.
    func testRealWorldMultiParagraphSymptom() {
        let p1a = "Heads up for reference here is how another panel provider we work with handles this and it is"
        let p1b = "worth reading carefully."
        let p2a = "The relevant part for your agreement is that they only supply a pseudonymized participant and the"
        let p2b = "recording itself is controlled entirely on our own platform."

        let input = "  \(p1a)\n  \(p1b)\n\n  \(p2a)\n  \(p2b)\n"
        let expected = "\(p1a) \(p1b)\n\n\(p2a) \(p2b)\n"
        XCTAssertEqual(reflowCopiedText(input), expected)
    }
}
