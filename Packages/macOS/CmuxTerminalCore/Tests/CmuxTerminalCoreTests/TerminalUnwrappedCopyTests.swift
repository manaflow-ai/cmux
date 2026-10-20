import CmuxTerminalCore
import Testing

@Suite
struct TerminalUnwrappedCopyTests {
    @Test func unwrapsClaudeReply() {
        let text = "⏺ The implementation now handles copied\n  paragraphs from the terminal correctly.  \n\n  - Keep the list item and its wrapped\n    continuation together.\n  - Keep the second item.\n\n  ```swift\n  let answer = 42   \n    print(answer)\n\n\n  ⏺ keep this marker in code\n  ```"
        let expected = "The implementation now handles copied paragraphs from the terminal correctly.\n\n- Keep the list item and its wrapped continuation together.\n- Keep the second item.\n\n```swift\nlet answer = 42\n  print(answer)\n\n\n⏺ keep this marker in code\n```"
        #expect(TerminalUnwrappedCopy(terminalColumns: 48).unwrappedText(text) == expected)
    }

    @Test func partialDragStartsMidLine() {
        let text = "starts midway through this paragraph\n  and continues on the following line.\n\n  A short line."
        #expect(TerminalUnwrappedCopy(terminalColumns: 44).unwrappedText(text)
            == "starts midway through this paragraph and continues on the following line.\n\nA short line.")
    }

    @Test func shortPartialFirstLineJoinsWithoutMeasuredWidth() {
        let text = "copy path first. The soft-wrap\n  join already exists, so the remaining problem is hard\n  wraps from TUIs that indent output."
        #expect(TerminalUnwrappedCopy(terminalColumns: 60).unwrappedText(text)
            == "copy path first. The soft-wrap join already exists, so the remaining problem is hard wraps from TUIs that indent output.")
    }

    @Test func nonPartialShortFirstLineKeepsItsBreak() {
        let text = "  copy path first. The soft-wrap\n  join already exists, so the remaining problem is hard\n  wraps from TUIs that indent output."
        #expect(TerminalUnwrappedCopy(terminalColumns: 60).unwrappedText(text)
            == "copy path first. The soft-wrap\njoin already exists, so the remaining problem is hard wraps from TUIs that indent output.")
    }

    @Test(arguments: [
        ("  -rw-r--r--   1 lucas staff 120 Oct 20 notes.txt\n  drwxr-xr-x   4 lucas staff 128 Oct 20 src", "-rw-r--r--   1 lucas staff 120 Oct 20 notes.txt\ndrwxr-xr-x   4 lucas staff 128 Oct 20 src"),
        ("  modified:   Sources/Terminal.swift\n  modified:   Sources/Clipboard.swift", "modified:   Sources/Terminal.swift\nmodified:   Sources/Clipboard.swift"),
        ("  ┌──────────────────┐\n  │ terminal output  │\n  └──────────────────┘", "┌──────────────────┐\n│ terminal output  │\n└──────────────────┘"),
    ]) func preservesColumnarOutput(fixture: (String, String)) {
        #expect(TerminalUnwrappedCopy(terminalColumns: 48).unwrappedText(fixture.0) == fixture.1)
    }

    @Test func preservesDeliberateShortLines() {
        let text = "  This line establishes the widest width.\n\n  Roses are red\n  Violets are blue"
        #expect(TerminalUnwrappedCopy(terminalColumns: 48).unwrappedText(text)
            == "This line establishes the widest width.\n\nRoses are red\nViolets are blue")
    }

    @Test(arguments: ["https://example.com/very/long/", "www.example.com/very/long/url", "/Users/lucas/projects/cmux/src"])
    func joinsSplitURLOrPath(token: String) {
        let text = "  \(token)\n  continuation"
        #expect(TerminalUnwrappedCopy(terminalColumns: 40).unwrappedText(text) == token + "continuation")
    }

    @Test func keepsSpaceAfterURLThatDoesNotFillWidth() {
        let text = "  Read https://example.com\n  documentation for details."
        #expect(TerminalUnwrappedCopy(terminalColumns: 36).unwrappedText(text)
            == "Read https://example.com documentation for details.")
    }

    @Test func preservesBackslashContinuation() {
        let text = "  curl https://example.com/api \\\n  --header 'Accept: application/json'"
        #expect(TerminalUnwrappedCopy(terminalColumns: 40).unwrappedText(text)
            == "curl https://example.com/api \\\n--header 'Accept: application/json'")
    }

    @Test func escapedBackslashAllowsReflow() {
        #expect(TerminalUnwrappedCopy(terminalColumns: 24).unwrappedText("  A long line ends \\\\\n  continuation")
            == "A long line ends \\\\ continuation")
    }

    @Test func collapsesBlankLinesOutsideFences() {
        #expect(TerminalUnwrappedCopy(terminalColumns: 80).unwrappedText("\n \n  first \t\n\n \n\n  second\t\n\n")
            == "first\n\nsecond")
        #expect(TerminalUnwrappedCopy(terminalColumns: 80).unwrappedText(" \t\n\n") == "")
    }

    @Test func narrowSelectionDoesNotReflow() {
        #expect(TerminalUnwrappedCopy(terminalColumns: 120).unwrappedText("  ⏺ Small paragraph\n    continued here.  ")
            == "Small paragraph\ncontinued here.")
        #expect(TerminalUnwrappedCopy(terminalColumns: 0).unwrappedText("  One line\n  next line")
            == "One line\nnext line")
    }

    @Test(arguments: ["⏺", "●", "⎿", "✻", "✳", "✶", "✢", "✽"])
    func stripsOnlyAgentMarkers(marker: String) {
        #expect(TerminalUnwrappedCopy(terminalColumns: 120).unwrappedText("  \(marker) Reply  \n    more") == "Reply\nmore")
        #expect(TerminalUnwrappedCopy(terminalColumns: 120).unwrappedText("  \(marker)reply") == marker + "reply")
    }

    @Test(arguments: ["• item", "└ file", "- item", "* item"])
    func preservesRealBullets(line: String) {
        #expect(TerminalUnwrappedCopy(terminalColumns: 80).unwrappedText("  " + line) == line)
    }

    @Test(arguments: ["- item", "* item", "+ item", "• item", "1. item", "1) item", "# heading", "> quote", "| table |", "$ command", "---", "***", "___", "- - -"])
    func structuralLinesStartNewParagraphs(line: String) {
        let text = "  This is the full width line\n  " + line
        #expect(TerminalUnwrappedCopy(terminalColumns: 38).unwrappedText(text)
            == "This is the full width line\n" + line)
    }

    @Test func continuationIndentMustMatchParagraph() {
        #expect(TerminalUnwrappedCopy(terminalColumns: 38).unwrappedText("  This is the full width line\n    extra indentation stays\n  done")
            == "This is the full width line\n  extra indentation stays\ndone")
    }

    @Test(arguments: ["- ", "1. ", "1) "])
    func joinsListContinuationAtContentColumn(prefix: String) {
        let text = "  " + prefix + "A long list item wraps here\n  " + String(repeating: " ", count: prefix.count) + "and continues here"
        #expect(TerminalUnwrappedCopy(terminalColumns: 40).unwrappedText(text)
            == prefix + "A long list item wraps here and continues here")
    }

    @Test func preservesTildeFencesAndRelativeIndent() {
        let text = "  ~~~~sh\n  ⏺ echo keep marker  \n    echo nested\n\n\n  ~~~\n  still code\n  ~~~~\n\n\n  done"
        #expect(TerminalUnwrappedCopy(terminalColumns: 28).unwrappedText(text)
            == "~~~~sh\n⏺ echo keep marker\n  echo nested\n\n\n~~~\nstill code\n~~~~\n\ndone")
    }

    @Test func rectangularSelectionKeepsRows() {
        let text = "  ⏺ This is a full width line  \n    continuation text  \n\n\n    next"
        #expect(TerminalUnwrappedCopy(terminalColumns: 36, rectangular: true).unwrappedText(text)
            == "This is a full width line\ncontinuation text\n\nnext")
    }

    @Test func softWrapsJoinBeforeUnwrapping() {
        let soft = TerminalSoftWrapCopy(hardWrapReflow: false).joiningSoftWraps(
            in: "  ⏺ A soft wrap with \na continuation\n    remaining hard row",
            wrapFlags: [true, false, false]
        )
        #expect(TerminalUnwrappedCopy(terminalColumns: 120).unwrappedText(soft)
            == "A soft wrap with a continuation\nremaining hard row")
    }

    @Test func fitTestRequiresWordToOverflow() {
        let unwrapper = TerminalUnwrappedCopy(terminalColumns: 30)
        #expect(unwrapper.unwrappedText("  widest line here\n\n  short line\n  first bit")
            == "widest line here\n\nshort line\nfirst bit")
        #expect(unwrapper.unwrappedText("  widest line here\n\n  short line\n  firsts bit")
            == "widest line here\n\nshort line firsts bit")
    }

    @Test func wrapEvidenceIncludesTheTwelveColumnBoundary() {
        let text = "  a long line here\n  continued"
        #expect(TerminalUnwrappedCopy(terminalColumns: 30).unwrappedText(text) == "a long line here continued")
        #expect(TerminalUnwrappedCopy(terminalColumns: 31).unwrappedText(text) == "a long line here\ncontinued")
    }

    @Test func widthsUseTerminalCellsAndPreDedentGutter() {
        #expect(TerminalUnwrappedCopy(terminalColumns: 32).unwrappedText("    日本語日本語日本語\n    continued")
            == "日本語日本語日本語 continued")
        #expect(TerminalUnwrappedCopy(terminalColumns: 32).unwrappedText("    cafe\u{301} cafe\u{301} cafe\u{301} cafe\u{301}\n    continued")
            == "cafe\u{301} cafe\u{301} cafe\u{301} cafe\u{301} continued")
    }
}
