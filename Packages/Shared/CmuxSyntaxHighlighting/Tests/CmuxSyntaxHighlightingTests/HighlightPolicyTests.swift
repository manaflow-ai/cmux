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
}
