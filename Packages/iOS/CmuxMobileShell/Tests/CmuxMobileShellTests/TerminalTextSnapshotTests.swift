import Testing

@testable import CmuxMobileShell

/// Verifies the line-budget capping the "View as Text" sheet applies to the
/// terminal's screen text: under-budget passthrough, last-N-lines truncation
/// (most recent output wins), and trailing-blank-row trimming (the libghostty
/// "screen" read includes written-but-blank rows below the last real output).
struct TerminalTextSnapshotTests {
    @Test func underBudgetPassesThrough() {
        let snapshot = TerminalTextSnapshot.capped(fullText: "a\nb\nc", lineBudget: 10)
        #expect(snapshot.text == "a\nb\nc")
        #expect(!snapshot.isTruncated)
        #expect(snapshot.lineBudget == 10)
    }

    @Test func overBudgetKeepsMostRecentLines() {
        let full = (1...10).map(String.init).joined(separator: "\n")
        let snapshot = TerminalTextSnapshot.capped(fullText: full, lineBudget: 3)
        #expect(snapshot.text == "8\n9\n10")
        #expect(snapshot.isTruncated)
        #expect(snapshot.lineBudget == 3)
    }

    @Test func exactBudgetIsNotTruncated() {
        let snapshot = TerminalTextSnapshot.capped(fullText: "a\nb\nc", lineBudget: 3)
        #expect(snapshot.text == "a\nb\nc")
        #expect(!snapshot.isTruncated)
    }

    @Test func trailingBlankRowsAreTrimmedBeforeBudgeting() {
        // Without the trim, the three blank tail rows would consume the budget
        // and push real output lines out of the capture.
        let snapshot = TerminalTextSnapshot.capped(fullText: "a\nb\n\n   \n\n", lineBudget: 2)
        #expect(snapshot.text == "a\nb")
        #expect(!snapshot.isTruncated)
    }

    @Test func interiorBlankLinesArePreserved() {
        let snapshot = TerminalTextSnapshot.capped(fullText: "a\n\nb", lineBudget: 10)
        #expect(snapshot.text == "a\n\nb")
        #expect(!snapshot.isTruncated)
    }

    @Test func whitespaceOnlyTextYieldsEmptySnapshot() {
        let snapshot = TerminalTextSnapshot.capped(fullText: "\n  \n\n", lineBudget: 5)
        #expect(snapshot.text.isEmpty)
        #expect(!snapshot.isTruncated)
    }

    @Test func emptyTextYieldsEmptySnapshot() {
        let snapshot = TerminalTextSnapshot.capped(fullText: "", lineBudget: 5)
        #expect(snapshot.text.isEmpty)
        #expect(!snapshot.isTruncated)
    }
}
