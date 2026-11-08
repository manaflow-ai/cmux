import CmuxSyntaxHighlighting
import Testing

@Suite("Highlight policy")
struct HighlightPolicyTests {
    private let policy = HighlightPolicy()

    @Test("Allows a small known-language buffer")
    func allowsSmallKnownLanguage() {
        #expect(policy.shouldHighlight(content: #"{"a":1}"#, language: "json"))
        #expect(
            policy.shouldHighlight(utf8Count: 8, lineCount: 1, language: "json")
        )
    }

    @Test("Rejects a missing language")
    func rejectsMissingLanguage() {
        #expect(!policy.shouldHighlight(content: #"{"a":1}"#, language: nil))
        #expect(!policy.shouldHighlight(utf8Count: 8, lineCount: 1, language: nil))
    }

    @Test("Rejects payloads above the byte ceiling")
    func rejectsOversizedBytes() {
        // kb:ceiling: HighlightPolicy.maximumHighlightedBytes
        let oversized = HighlightPolicy.maximumHighlightedBytes + 1
        #expect(
            !policy.shouldHighlight(utf8Count: oversized, lineCount: 1, language: "swift")
        )
    }

    @Test("Rejects payloads above the line ceiling")
    func rejectsOversizedLines() {
        // kb:ceiling: HighlightPolicy.maximumHighlightedLines
        let oversized = HighlightPolicy.maximumHighlightedLines + 1
        #expect(
            !policy.shouldHighlight(utf8Count: 64, lineCount: oversized, language: "swift")
        )
    }

    @Test("Rejects nonpositive precomputed line counts")
    func rejectsNonpositiveLineCounts() {
        #expect(!policy.shouldHighlight(utf8Count: 8, lineCount: 0, language: "swift"))
        #expect(!policy.shouldHighlight(utf8Count: 8, lineCount: -1, language: "swift"))
    }

    @Test("Content path rejects excessive lines")
    func contentPathRejectsExcessiveLines() {
        let content = String(repeating: "line\n", count: HighlightPolicy.maximumHighlightedLines)
        #expect(!policy.shouldHighlight(content: content, language: "swift"))
    }

    @Test("Counts lines as one plus newlines")
    func countsLines() {
        #expect(policy.lineCount(in: "") == 1)
        #expect(policy.lineCount(in: "one") == 1)
        #expect(policy.lineCount(in: "one\ntwo\nthree") == 3)
    }

    @Test("Line counting ignores grapheme boundaries")
    func countsLinesOverMultiByteGraphemes() {
        // Newline detection must not depend on grapheme decoding around the
        // surrounding multi-code-unit emoji.
        let emojiLines = "😀\n😀\n😀"
        #expect(policy.lineCount(in: emojiLines) == 3)
        #expect(policy.shouldHighlight(content: emojiLines, language: "swift"))
    }

    @Test("Line counting treats Cocoa separators and CRLF correctly")
    func countsCocoaLineSeparators() {
        #expect(policy.lineCount(in: "one\rtwo") == 2)
        #expect(policy.lineCount(in: "one\r\ntwo") == 2)
        #expect(policy.lineCount(in: "one\u{2028}two\u{2029}three") == 3)
    }
}
