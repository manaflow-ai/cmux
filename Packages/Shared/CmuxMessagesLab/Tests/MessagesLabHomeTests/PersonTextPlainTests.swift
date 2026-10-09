import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// Messages shows a person's text as typed: only an agent's text is Markdown.
/// MessagesLab's own Markdown engine (Layout -> Markdown.layout) styles every
/// rich text part, so Home must keep a person's markers (`**`, `` ` ``) as written.
@MainActor @Suite struct PersonTextPlainTests {
    @Test func aPersonsMarkdownMarkersStayAsTyped() throws {
        let (p, c) = Fixture2.projection()
        let items = [Fixture2.item(1, Fixture2.them, "Plan: **ship it** after `verify-clean`."),
                     Fixture2.item(2, Fixture2.me, "Thanks, **looks good** and `done`.")]
        p.apply(items: items, summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        c.host.layoutSubtreeIfNeeded()
        c.demo.layoutIfNeeded()
        c.demo.collection.layoutIfNeeded()
        let mine = try #require(c.demo.lastTextRow(mine: true))
        #expect(mine.row.markdown == nil, "a person's text takes the plain path")
        #expect(mine.row.text?.text == "Thanks, **looks good** and `done`.")
        let agent = try #require(c.demo.lastTextRow(mine: false))
        #expect(agent.row.text?.text == "Plan: ship it after verify-clean.", "an agent's text stays Markdown")
    }
}
