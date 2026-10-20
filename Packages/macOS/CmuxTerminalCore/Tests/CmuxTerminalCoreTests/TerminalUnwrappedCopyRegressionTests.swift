import CmuxTerminalCore
import Testing
import Foundation

@Suite
struct TerminalUnwrappedCopyRegressionTests {
    @Test func knownColumnZeroPreservesCodeIndentation() {
        let text = "def greet():\n    print(\"hello\")"
        #expect(TerminalUnwrappedCopy(terminalColumns: 120, firstLineStartColumn: 0)
            .unwrappedText(text) == text)
    }

    @Test func knownPartialFirstLineUsesStartColumnForFit() {
        let text = "selected fragment\n  continuing prose at the full row width\n  and more words"
        #expect(TerminalUnwrappedCopy(terminalColumns: 40, firstLineStartColumn: 3)
            .unwrappedText(text) == "selected fragment\ncontinuing prose at the full row width and more words")
        #expect(TerminalUnwrappedCopy(terminalColumns: 40, firstLineStartColumn: 15)
            .unwrappedText(text) == "selected fragment continuing prose at the full row width and more words")
    }

    @Test func knownPartialFirstLineDoesNotDependOnIndentation() {
        let text = "selected fragment\ncontinuing prose at the full row width\nand more words"
        #expect(TerminalUnwrappedCopy(terminalColumns: 40, firstLineStartColumn: 15)
            .unwrappedText(text) == "selected fragment continuing prose at the full row width and more words")
    }

    @Test func completeURLKeepsSpaceBeforeFollowingWord() {
        #expect(TerminalUnwrappedCopy(terminalColumns: 32)
            .unwrappedText("  See https://example.com\n  for details.")
            == "See https://example.com for details.")
    }

    @Test(arguments: [".", "!", "?"])
    func independentSentencesKeepRows(punctuation: String) {
        let text = "Build completed successfully\(punctuation)\nTests completed successfully."
        #expect(TerminalUnwrappedCopy(terminalColumns: 40).unwrappedText(text) == text)
    }

    @Test(arguments: ["", "- ", "1. "])
    func singleTokenRowsStaySeparate(prefix: String) {
        let filename = "very-long-independent-filename-one"
        let text = prefix + filename + "\n" + String(repeating: " ", count: prefix.count)
            + "another-independent-filename-two"
        #expect(TerminalUnwrappedCopy(terminalColumns: 40).unwrappedText(text) == text)
    }

    @Test(arguments: ["/", "-", "_", ".", "?", "=", "&", "#", "%", "~", "+"])
    func splitTokenTrailingEvidenceJoinsWithoutSpace(mark: String) {
        let token = "example.com/a/long/split/token" + mark
        #expect(TerminalUnwrappedCopy(terminalColumns: 40)
            .unwrappedText("  " + token + "\n  continuation") == token + "continuation")
    }

    @Test(arguments: ["/", "?", "=", "&", "#", "%", "."])
    func splitTokenLeadingEvidenceJoinsWithoutSpace(mark: String) {
        let token = "example.com/a/long/split/token"
        let continuation = "next" + mark + "part"
        #expect(TerminalUnwrappedCopy(terminalColumns: 40)
            .unwrappedText("  " + token + "\n  " + continuation) == token + continuation)
    }

    @Test(arguments: [",", ":", ".", ";"])
    func proseRowFillingWidthKeepsSpace(mark: String) {
        let text = "  This row fills the width and ends" + mark + "\n  and the sentence goes on."
        #expect(TerminalUnwrappedCopy(terminalColumns: 40).unwrappedText(text)
            == "This row fills the width and ends" + mark + " and the sentence goes on.")
    }

    @Test func urlCutMidWordInsideListItemJoinsWithoutSpace() {
        let text = "  - Copy Unwrapped rejoins hard-wrapped paragraphs and list items, and keeps\n"
            + "    lists on their own lines.\n"
            + "  - See https://github.com/manaflow-ai/cmux/pull/4138/files?diff=split&w=1#dif\n"
            + "    f-abc for the earlier attempt."
        #expect(TerminalUnwrappedCopy(terminalColumns: 80, firstLineStartColumn: 0).unwrappedText(text)
            == "- Copy Unwrapped rejoins hard-wrapped paragraphs and list items, and keeps lists on their own lines.\n"
            + "- See https://github.com/manaflow-ai/cmux/pull/4138/files?diff=split&w=1#diff-abc for the earlier attempt.")
    }

    @Test func longFencedCodeDoesNotSuppressParagraphReflow() {
        let code = String(repeating: "x", count: 80)
        let text = "```\n" + code + "\n```\n\nThis paragraph wraps near the edge\nand continues on the next row."
        #expect(TerminalUnwrappedCopy(terminalColumns: 40).unwrappedText(text)
            == "```\n" + code + "\n```\n\nThis paragraph wraps near the edge and continues on the next row.")
    }

    @Test func softUnwrappedLongLineDoesNotSuppressParagraphReflow() {
        let long = String(repeating: "word ", count: 16) + "end"
        let text = long + "\n\nThis paragraph wraps near the edge\nand continues on the next row."
        #expect(TerminalUnwrappedCopy(terminalColumns: 40).unwrappedText(text)
            == long + "\n\nThis paragraph wraps near the edge and continues on the next row.")
    }

    @Test func protectedAndOversizedLinesDoNotProvideWrapEvidence() {
        for text in ["short fragment\n  continued here\n\n  ```\n  " + String(repeating: "x", count: 36) + "\n  ```",
                     "short fragment\n  continued here\n\n  " + String(repeating: "x", count: 80)] {
            #expect(TerminalUnwrappedCopy(terminalColumns: 40).unwrappedText(text)
                == text.replacingOccurrences(of: "\n  ", with: "\n"))
        }
    }
}
