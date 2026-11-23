import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// CMUX-20: Chief's `**bold**` draws bold on the phone, as the Mac's Home
/// does, and code stays as written.
@Suite struct ChiefMarkdownBoldTests {
    private func bold(_ rendered: ChiefMarkdownBold.Rendered) -> [String] {
        let text = rendered.text as NSString
        return rendered.runs.map {
            #expect($0.style == .bold)
            return text.substring(with: $0.range)
        }
    }

    @Test func strongEmphasisBecomesBoldRuns() {
        let rendered = ChiefMarkdownBold.render("**#36125 is green** at 64d6b1b and __done__.")
        #expect(rendered.text == "#36125 is green at 64d6b1b and done.")
        #expect(bold(rendered) == ["#36125 is green", "done"])
    }

    @Test func codeIsNeverBold() {
        let span = ChiefMarkdownBold.render("Run `**not bold**` then **see `cmux ls` now**.")
        #expect(span.text == "Run `**not bold**` then see `cmux ls` now.")
        #expect(bold(span) == ["see ", " now"])

        let fence = "Before **a**\n```\nlet x = **y**\n```\n~~~\n__init__\n~~~\nAfter **b**"
        let fenced = ChiefMarkdownBold.render(fence)
        #expect(fenced.text == "Before a\n```\nlet x = **y**\n```\n~~~\n__init__\n~~~\nAfter b")
        #expect(bold(fenced) == ["a", "b"])
    }

    @Test func plainMarkdownIsUntouched() {
        for text in [
            "snake__case__name and file__name",
            "2 ** 3 is eight; a ** b",
            "** spaced ** and **unclosed",
            "\\*\\*literal\\*\\*",
            "*italic* and _also_",
            "| a | b |\n|---|---|",
            "",
        ] {
            let rendered = ChiefMarkdownBold.render(text)
            #expect(rendered.text == text, "\(text)")
            #expect(rendered.runs.isEmpty, "\(text)")
        }
    }

    @Test func boldInsideATableCell() {
        let rendered = ChiefMarkdownBold.render("| **PR** | state |\n| #1 | **green** |")
        #expect(rendered.text == "| PR | state |\n| #1 | green |")
        #expect(bold(rendered) == ["PR", "green"])
    }

    @Test func multibyteTextKeepsUTF16Ranges() {
        let rendered = ChiefMarkdownBold.render("🚀 **ship ✅ it** now")
        #expect(rendered.text == "🚀 ship ✅ it now")
        #expect(bold(rendered) == ["ship ✅ it"])
    }

    @Test func linksAndMentionsMoveWithTheText() throws {
        // "**Done** see PR #1 @Chief" after link extraction of "[PR #1](…)".
        let text = "**Done** see **PR #1** @Chief"
        let link = ConversationTextLink(location: 13, length: 9, url: try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/1")))
        let mention = ConversationMention(participantID: "agent_mux", location: 23, length: 6)
        let rendered = ChiefMarkdownBold.render(text, links: [link], mentions: [mention])
        let shown = rendered.text as NSString
        #expect(rendered.text == "Done see PR #1 @Chief")
        #expect(shown.substring(with: try #require(rendered.links.first).range) == "PR #1")
        #expect(shown.substring(with: try #require(rendered.mentions.first).nsRange) == "@Chief")
    }

    @Test func wireMessagesFromChiefCarryBoldAndMineStayAsTyped() throws {
        let wire = ChiefWire(identity: .standard)
        let part: [String: Any] = ["type": "text", "text": "**Review:** SHIP at [`64d6b1b`](https://github.com/manaflow-ai/cmux/commit/64d6b1b)."]
        let chief = try #require(wire.message(["id": "m1", "seq": 1, "author": wire.identity.chiefID, "parts": [part], "reactions": []], peerReadSeq: 0))
        #expect(chief.text == "Review: SHIP at `64d6b1b`.")
        #expect(chief.textRuns == [ConversationTextRun(location: 0, length: 7, style: .bold)])
        #expect((chief.text as NSString).substring(with: try #require(chief.links.first).range) == "`64d6b1b`")

        let mine = try #require(wire.message(["id": "m2", "seq": 2, "author": wire.identity.meID, "parts": [["type": "text", "text": "**typed**"]], "reactions": []], peerReadSeq: 0))
        #expect(mine.text == "**typed**")
        #expect(mine.textRuns.isEmpty)
    }

    @Test func liveBubbleIsBoldToo() {
        let attributed = ChiefMarkdownBold.attributed("so far **green**")
        #expect(String(attributed.characters) == "so far green")
        let intents = attributed.runs.map { String(attributed[$0.range].characters) + ":" + ($0.inlinePresentationIntent == .stronglyEmphasized ? "b" : "-") }
        #expect(intents == ["so far :-", "green:b"])
    }
}
