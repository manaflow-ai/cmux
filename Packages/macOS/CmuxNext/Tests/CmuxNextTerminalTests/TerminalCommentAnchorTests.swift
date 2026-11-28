import CmuxNextTerminal
import Testing

/// A terminal comment's scrollback anchor (comment-threads-v1): the rows a selection covered, and
/// finding them again after output scrolled them away or the oldest history was trimmed.
struct TerminalCommentAnchorTests {
    static let screen = TerminalCommentAnchor.lines("""
        $ swift build
        Compiling CmuxNextDiff CommentThreads.swift
        error: cannot find 'x' in scope
            let y = x + 1
        $ swift build
        Compiling CmuxNextDiff CommentThreads.swift
        error: cannot find 'x' in scope
            let y = x + 1
        $ 
        """)

    @Test func theNearestRowWithTheQuotesFirstLineIsTheAnchor() {
        let quote = "error: cannot find 'x' in scope\n    let y = x + 1\n"
        // The same error printed twice: the one nearest where the comment was.
        #expect(TerminalCommentAnchor.locate(quote, in: Self.screen, near: 2) == 2)
        #expect(TerminalCommentAnchor.locate(quote, in: Self.screen, near: 6) == 6)
        // Trimmed history moved every row up by one: still the nearer copy.
        #expect(TerminalCommentAnchor.locate(quote, in: Self.screen, near: 7) == 6)
    }

    @Test func aSelectionStartingMidRowOrWithBlankLinesStillMatches() {
        #expect(TerminalCommentAnchor.locate("cannot find 'x' in scope", in: Self.screen, near: 0) == 2)
        #expect(TerminalCommentAnchor.locate("\n   \n  let y = x + 1", in: Self.screen, near: 8) == 7)
    }

    @Test func textNoLongerOnTheScreenHasNoAnchor() {
        #expect(TerminalCommentAnchor.locate("warning: unused variable", in: Self.screen, near: 2) == nil)
        #expect(TerminalCommentAnchor.locate("  \n\n", in: Self.screen, near: 2) == nil)
        #expect(TerminalCommentAnchor.locate("ls", in: [], near: 0) == nil)
    }

    @Test func aQuoteCoversOneRowPerLinePlusItsWraps() {
        #expect(TerminalCommentAnchor.rowSpan(of: "one", columns: 80, startColumn: 0) == 1)
        #expect(TerminalCommentAnchor.rowSpan(of: "one\ntwo\n", columns: 80, startColumn: 0) == 2)
        // 100 characters in an 80-column grid wrap once.
        #expect(TerminalCommentAnchor.rowSpan(of: String(repeating: "a", count: 100), columns: 80, startColumn: 0) == 2)
        // A first line starting at column 70 wraps after 10.
        #expect(TerminalCommentAnchor.rowSpan(of: String(repeating: "a", count: 20) + "\nb", columns: 80, startColumn: 70) == 3)
        #expect(TerminalCommentAnchor.rowSpan(of: "a\n\nb", columns: 80, startColumn: 0) == 3)
    }
}
