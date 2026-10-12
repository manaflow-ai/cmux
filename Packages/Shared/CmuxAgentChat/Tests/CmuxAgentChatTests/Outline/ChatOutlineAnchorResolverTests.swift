import CmuxAgentChat
import Foundation
import Testing

@Suite("Chat outline anchor resolver")
struct ChatOutlineAnchorResolverTests {
    private func entry(_ id: String, _ title: String) -> ChatOutlineEntry {
        ChatOutlineEntry(id: id, seq: 0, timestamp: Date(timeIntervalSince1970: 0), title: title)
    }

    @Test("finds each prompt row after ANSI cleanup, ignoring prose mentions")
    func findsPromptRows() {
        let entries = [entry("a", "Review the login flow"), entry("b", "Now fix it")]
        let history = [
            "shell$ claude",
            "\u{1B}[32m> Review the login flow\u{1B}[0m",
            "I will review the login flow",
            "⏺ Done.",
            "",
            "  › Now   fix it",
            "⏺ Fixed.",
        ].joined(separator: "\n")

        let rows = ChatOutlineAnchorResolver().rows(for: entries, in: history)

        #expect(rows == ["a": 1, "b": 5])
    }

    @Test("a repeated prompt anchors each copy in order, newest first")
    func repeatedPromptsAnchorInOrder() {
        let entries = [entry("a", "yes"), entry("b", "continue"), entry("c", "yes")]
        let history = "❯ yes\nok\n❯ continue\nok\n❯ yes\nok\n"

        let rows = ChatOutlineAnchorResolver().rows(for: entries, in: history)

        #expect(rows == ["a": 0, "b": 2, "c": 4])
    }

    @Test("when history holds fewer copies, the newest entries keep them")
    func trimmedHistoryAnchorsNewestCopies() {
        let first = entry("first", "Review the login flow")
        let second = entry("second", "Review the login flow")
        let history = "old output\n❯ Review the login flow\nresult\n"

        let resolver = ChatOutlineAnchorResolver()

        #expect(resolver.row(for: second, among: [first, second], in: history) == 1)
        #expect(resolver.row(for: first, among: [first, second], in: history) == nil)
    }

    @Test("a newest prompt that is not echoed yet never borrows an older copy's row")
    func unechoedNewestPromptStaysUnanchored() {
        let entries = [entry("a", "yes"), entry("b", "fix"), entry("c", "yes")]
        let history = "❯ yes\nok\n❯ fix\nworking\n"

        let rows = ChatOutlineAnchorResolver().rows(for: entries, in: history)

        #expect(rows == ["a": 0, "b": 2])
    }

    @Test("markdown headings, quotes and shell prompts are not prompt rows")
    func proseLookalikesAreNotPrompts() {
        let entries = [entry("a", "Summary"), entry("b", "ls")]
        let history = "# Summary\n$ ls\n% ls\n"

        #expect(ChatOutlineAnchorResolver().rows(for: entries, in: history).isEmpty)
    }

    @Test("hundreds of turns resolve against a long scrollback quickly")
    func largeScrollbackResolves() {
        let entries = (0..<400).map { entry("e\($0)", "prompt number \($0) about the build") }
        var lines: [String] = []
        for index in 0..<400 {
            lines.append("❯ prompt number \(index) about the build")
            lines.append(contentsOf: (0..<100).map { "> quoted output \($0) of turn \(index)" })
        }
        let rows = ChatOutlineAnchorResolver().rows(for: entries, in: lines.joined(separator: "\n"))

        #expect(rows.count == 400)
        #expect(rows["e399"] == 399 * 101)
    }

    @Test("an older prompt never anchors below a newer one")
    func anchorsStayMonotonic() {
        // The redraw printed "b" again after "a"'s only copy; "a" must not
        // claim a row below "b".
        let entries = [entry("a", "alpha"), entry("b", "beta")]
        let history = "❯ beta\n❯ alpha\nx\n❯ beta\n"

        let rows = ChatOutlineAnchorResolver().rows(for: entries, in: history)

        #expect(rows == ["a": 1, "b": 3])
    }

    @Test("soft-wrapped prompts match across rows, between or inside words")
    func matchesWrappedPrompts() {
        let resolver = ChatOutlineAnchorResolver()
        let target = entry("w", "Review the login flow")

        #expect(resolver.rows(for: [target], in: "❯ Review the\nlogin flow\n") == ["w": 0])
        #expect(resolver.rows(for: [target], in: "❯ Review the lo\ngin flow\n") == ["w": 0])
        #expect(resolver.rows(for: [target], in: "❯ Review the\n\nlogin flow\n").isEmpty)
    }

    @Test("clipped titles match a longer echoed prompt")
    func clippedTitlesMatchPrefix() {
        let title = String(String(repeating: "abc ", count: 60).prefix(ChatOutlineEntry.titleLimit))
        let clipped = entry("c", title)
        #expect(clipped.isTitleClipped)

        let rows = ChatOutlineAnchorResolver().rows(for: [clipped], in: "\n❯ \(title) and more words\n")

        #expect(rows == ["c": 1])
        #expect(ChatOutlineAnchorResolver().rows(for: [entry("d", "abc")], in: "❯ abc abc\n").isEmpty)
    }

    @Test("prompts absent from history, such as pasted-text placeholders, stay unanchored")
    func missingPromptsHaveNoRow() {
        let entries = [entry("a", "first"), entry("b", "a long pasted prompt")]
        let history = "❯ first\n❯ [Pasted text #1 +20 lines]\n"

        #expect(ChatOutlineAnchorResolver().rows(for: entries, in: history) == ["a": 0])
    }

    @Test("row offset maps a partial capture to absolute rows")
    func rowOffsetIsApplied() {
        let rows = ChatOutlineAnchorResolver().rows(
            for: [entry("a", "hello")],
            in: "x\n❯ hello\n",
            rowOffset: 500
        )

        #expect(rows == ["a": 501])
    }
}
