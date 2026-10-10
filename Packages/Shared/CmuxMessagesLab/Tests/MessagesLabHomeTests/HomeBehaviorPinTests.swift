import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// What the Home transcript shows and copies today, checked on its rows (not on
/// HomeMarkdown's runs), so the move to MessagesLab's own Selection and Markdown
/// engine keeps it: an agent's Markdown without markers, a fenced block in one
/// bubble, a mention part as written, drag and double-click selection and copy.
@MainActor @Suite struct HomeBehaviorPinTests {
    private func pane(_ items: [TranscriptItem]) -> ChatController {
        let (p, c) = Fixture2.projection()
        p.apply(items: items, summary: Fixture2.summary(lastSeq: Seq(items.count)), typing: [], hasOlder: false)
        c.host.layoutSubtreeIfNeeded(); c.demo!.layoutIfNeeded(); c.demo!.collection.layoutIfNeeded()
        return c
    }

    /// The text each part row shows, in transcript order.
    private func shown(_ c: ChatController) -> [String] {
        c.demo!.model.rows.compactMap {
            guard case let .part(row) = $0.spec.kind else { return nil }
            return row.markdown?.plain ?? row.text?.text
        }
    }

    private func event(_ type: NSEvent.EventType, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    @Test func anAgentsMarkdownShowsWithoutItsMarkers() {
        let c = pane([Fixture2.item(1, Fixture2.them, "**Code** and `gh` and *this* and [docs](https://cmux.com)")])
        let text = shown(c).joined()
        #expect(text.contains("Code and gh and this and docs"), "\(text)")
        #expect(!text.contains("**") && !text.contains("`") && !text.contains("]("), "\(text)")
    }

    @Test func aFencedBlockIsOneBubbleWithoutItsFences() {
        let c = pane([Fixture2.item(1, Fixture2.them, "Run:\n```\nswift test\n```\nDone.")])
        let rows = shown(c)
        #expect(rows.count == 1, "one bubble: \(rows)")
        #expect(rows.first?.contains("swift test") == true && rows.first?.contains("```") == false, "\(rows)")
    }

    @Test func aPartWithAMentionShowsAsWritten() {
        let text = "@Austin look at **this**"
        let item = TranscriptItem(key: IdempotencyKey("k1"), seq: 1, author: Fixture2.them,
                                  parts: [.text(text, mentions: [Mention(start: 0, length: 7, participant: Fixture2.me)])],
                                  createdAt: Fixture2.start, delivery: .committed, messageID: MessageID("msg_1"))
        #expect(shown(pane([item])) == [text])
    }

    @Test func theSidebarPreviewDropsAnAgentsMarkersOnly() {
        let summary = Fixture2.summary(lastSeq: 1)
        #expect(HomeMarkdownPreview("**Done** with `gh`", author: Fixture2.them, in: summary).text == "Done with gh")
        #expect(HomeMarkdownPreview("**Done** with `gh`", author: Fixture2.me, in: summary).text == "**Done** with `gh`")
    }

    @Test func aDragAcrossTwoMessagesCopiesBothTexts() throws {
        let c = pane([Fixture2.item(1, Fixture2.them, "First reply here"), Fixture2.item(2, Fixture2.me, "Second one mine")])
        let a = try #require(c.demo!.lastTextRow(mine: false)), b = try #require(c.demo!.lastTextRow(mine: true))
        let from = CGPoint(x: a.body.minX + Fixture.bubblePadX + 1, y: a.body.minY + Fixture.bubblePadY + Fixture.lineHeight / 2)
        let to = CGPoint(x: b.body.maxX - Fixture.bubblePadX - 1, y: b.body.minY + Fixture.bubblePadY + Fixture.lineHeight / 2)
        c.mouseDown(at: from, event(.leftMouseDown))
        c.mouseDragged(at: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), event(.leftMouseDragged))
        c.mouseDragged(at: to, event(.leftMouseDragged))
        c.mouseUp(at: to, event(.leftMouseUp))
        #expect(c.selection.selectedText == "First reply here\nSecond one mine")
    }

    @Test func aDoubleClickSelectsTheWord() throws {
        let c = pane([Fixture2.item(1, Fixture2.them, "alpha bravo charlie")])
        let a = try #require(c.demo!.lastTextRow(mine: false))
        let tl = try #require(a.row.text)
        let x = CTLineGetOffsetForStringIndex(CTLineCreateWithAttributedString(tl.attributed(color: .white, linkColor: .white)), 8, nil)
        c.doubleClicked(CGPoint(x: a.body.minX + Fixture.bubblePadX + x, y: a.body.minY + Fixture.bubblePadY + Fixture.lineHeight / 2))
        #expect(c.selection.selectedText == "bravo")
    }
}
