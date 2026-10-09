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
        c.demo!.layoutIfNeeded()
        c.demo!.collection.layoutIfNeeded()
        let mine = try #require(c.demo!.lastTextRow(mine: true))
        #expect(mine.row.markdown == nil, "a person's text takes the plain path")
        #expect(mine.row.text?.text == "Thanks, **looks good** and `done`.")
        let agent = try #require(c.demo!.lastTextRow(mine: false))
        #expect(agent.row.text?.text == "Plan: ship it after verify-clean.", "an agent's text stays Markdown")
    }

    private func laidOut(_ c: ChatController) {
        c.host.layoutSubtreeIfNeeded(); c.demo.layoutIfNeeded(); c.demo.collection.layoutIfNeeded()
    }

    /// My own send never went through HomeMapping before MessagesLab's reducer made and
    /// measured its local message (`.send`), so it showed as Markdown at once and, measured
    /// under the same id, after the owner's echo too. A person's text shows as typed on every
    /// path: the local message at the press, the committed echo, and a later open.
    @Test func mySendShowsAsTypedAtThePressAfterTheEchoAndAfterAReopen() async throws {
        let typed = "**bold** and _x_"
        let source = ScriptedSource(me: Fixture2.people[0], summary: Fixture2.summary(lastSeq: 1),
                                    messages: [Fixture2.message(1, Fixture2.them, "Hi")])
        let store = HomeStore(source: source)
        store.start()
        defer { store.stop() }
        await waitUntil { store.isOnline && store.me != nil }
        await store.open(Fixture2.id)
        let (p, c) = Fixture2.projection(store: store)
        p.start()
        c.dispatch(.setDraft(typed))
        p.send()
        laidOut(c)
        let atPress = try #require(c.demo.lastTextRow(mine: true))
        #expect(atPress.row.markdown == nil, "the local message at the press takes the plain path")
        #expect(atPress.row.text?.text == typed)
        let local = try #require(c.store.state.conversation.messages.last)
        let key = try #require(p.aliases.first(where: { $0.value == local.id })?.key)
        await waitUntil { store.transcript(for: Fixture2.id).contains { $0.key == key } }
        await source.publish(.message(Fixture2.message(2, Fixture2.me, typed, key: key.rawValue), rev: 11))
        await waitUntil { p.shown.last?.seq == 2 }
        laidOut(c)
        let echoed = try #require(c.demo.lastTextRow(mine: true))
        #expect(echoed.row.markdown == nil, "the committed echo takes the plain path")
        #expect(echoed.row.text?.text == typed)
        p.stop()
        let (p2, c2) = Fixture2.projection(store: store)
        p2.start()
        laidOut(c2)
        let reopened = try #require(c2.demo.lastTextRow(mine: true))
        #expect(reopened.row.markdown == nil, "a later open takes the plain path")
        #expect(reopened.row.text?.text == typed)
        p2.stop()
    }
}
