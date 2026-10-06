import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// The adapter keeps HomeStore the single writer: the view animates what the
/// store says, and the user's changes leave as HomeIntents (home-mac.md 1-2).
@MainActor @Suite(.serialized) struct HomeProjectionTests {
    let me = Fixture2.me, them = Fixture2.them

    @Test func anUnchangedUpdateDoesNoWork() {
        let (p, c) = Fixture2.projection()
        let items = Fixture2.history(20)
        p.apply(items: items, summary: Fixture2.summary(lastSeq: 20), typing: [], hasOlder: false)
        #expect(c.store.state.conversation.messages.count == 20)
        p.apply(items: items, summary: Fixture2.summary(lastSeq: 20), typing: [], hasOlder: false)
        #expect(p.appliedUpdates == 0)
        p.apply(items: items + [Fixture2.item(21, them, "New")], summary: Fixture2.summary(lastSeq: 21), typing: [], hasOlder: false)
        #expect(p.appliedUpdates == 1)
        #expect(c.store.state.conversation.messages.last?.id == "k21")
    }

    @Test func typingShowsMessagesLabsIndicator() {
        let (p, c) = Fixture2.projection()
        let items = Fixture2.history(5)
        p.apply(items: items, summary: Fixture2.summary(lastSeq: 5), typing: [], hasOlder: false)
        p.apply(items: items, summary: Fixture2.summary(lastSeq: 5), typing: [them], hasOlder: false)
        #expect(c.store.state.ui.typing == ["agent_chief"])
        #expect(c.demo.model.rows.last?.spec.key == "typing")
        p.apply(items: items + [Fixture2.item(6, them, "Done")], summary: Fixture2.summary(lastSeq: 6), typing: [], hasOlder: false)
        #expect(c.store.state.ui.typing.isEmpty)
    }

    /// A host notice (Home's "quit older builds to merge Chief history") is a
    /// row of the transcript, MessagesLab's centered system row under the
    /// newest message, not an overlay on top of the view.
    @Test func aNoticeIsTheTranscriptsSystemRowUnderTheNewestMessage() throws {
        let (p, c) = Fixture2.projection()
        let items = Fixture2.history(3)
        p.apply(items: items, summary: Fixture2.summary(lastSeq: 3), typing: [], hasOlder: false)
        let text = "Quit older cmux DEV builds to merge Chief history"
        p.notice = text
        let row = try #require(c.demo.model.rows.last, "a row under the newest message")
        #expect(row.spec.key == "notice")
        guard case let .separator(bold, rest) = row.spec.kind else {
            Issue.record("the notice is MessagesLab's system row, not \(row.spec.kind)")
            return
        }
        #expect(bold.isEmpty && rest == text)
        // A new message keeps the notice at the end; clearing it removes the row.
        p.apply(items: items + [Fixture2.item(4, them, "Later")], summary: Fixture2.summary(lastSeq: 4), typing: [], hasOlder: false)
        #expect(c.demo.model.rows.last?.spec.key == "notice")
        p.notice = nil
        #expect(!c.demo.model.rows.contains { $0.spec.key == "notice" })
    }

    private func onlineStore(_ items: [CmuxHomeCore.Message] = []) async -> (HomeStore, ScriptedSource) {
        let source = ScriptedSource(me: Fixture2.people[0], summary: Fixture2.summary(lastSeq: Seq(items.count)), messages: items)
        let store = HomeStore(source: source)
        store.start()
        await waitUntil { store.isOnline && store.me != nil }
        await store.open(Fixture2.id)
        return (store, source)
    }

    @Test func aSendIsAnIntentAndTheMorphFliesAtThePress() async throws {
        let (store, source) = await onlineStore((1...4).map { Fixture2.message(Seq($0), $0 % 2 == 0 ? me : them, "Line \($0)") })
        let (p, c) = Fixture2.projection(store: store)
        p.start()
        #expect(c.store.state.conversation.messages.count == 4)
        c.dispatch(.setDraft("Hello there"))
        p.send()
        let local = try #require(c.store.state.conversation.messages.last)
        #expect(local.parts.first?.plainText == "Hello there")
        #expect(local.status == .sending)
        #expect(c.demo.morphs.count == 1, "MessagesLab's send morph")
        #expect(c.store.state.ui.draft.text.isEmpty)
        let key = try #require(p.aliases.first(where: { $0.value == local.id })?.key)
        await waitUntil { store.transcript(for: Fixture2.id).contains { $0.key == key } }
        let sent = await source.submitted
        #expect(sent.count == 1)
        #expect(sent.first?.key == key)
        #expect(sent.first?.op == .sendMessage(conversation: Fixture2.id, parts: [.text("Hello there")]))
        // The pending item and the owner's echo only move the local message's status.
        await waitUntil { p.shown.contains { $0.key == key } }
        #expect(c.store.state.conversation.messages.filter { $0.parts.first?.plainText == "Hello there" }.count == 1)
        await source.publish(.message(Fixture2.message(5, me, "Hello there", key: key.rawValue), rev: 11))
        await waitUntil { p.shown.last?.seq == 5 }
        if case .delivered = c.store.state.conversation.messages.last?.status {} else {
            Issue.record("committed echo shows Delivered, got \(String(describing: c.store.state.conversation.messages.last?.status))")
        }
        #expect(c.store.state.conversation.messages.last?.id == local.id, "no remove and insert")
        p.stop()
        store.stop()
    }

    @Test func offlineTheTextStaysADraft() {
        let (p, c) = Fixture2.projection()
        p.apply(items: Fixture2.history(3), summary: Fixture2.summary(lastSeq: 3), typing: [], hasOlder: false)
        c.dispatch(.setDraft("Not yet"))
        p.send()
        #expect(c.store.state.ui.draft.text == "Not yet")
        #expect(c.store.state.conversation.messages.count == 3)
    }

    @Test func aSendRefusedBeforeTheLogReturnsItsText() {
        let (p, c) = Fixture2.projection()
        p.apply(items: Fixture2.history(2), summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        // The press flew the morph; the owner then refused the intent before
        // logging it (it never reached HomeStore's transcript).
        c.dispatch(.setDraft("Refused"))
        c.dispatch(.send)
        let local = c.store.state.conversation.messages.last!.id
        let key = IdempotencyKey("cmk_never_logged")
        p.rememberAlias(key, local)
        p.sendRefused(key, text: "Refused", .ownerUnreachable)
        #expect(!c.store.state.conversation.messages.contains { $0.id == local })
        #expect(c.store.state.ui.draft.text == "Refused")
        #expect(p.aliases[key] == nil)
    }

    @Test func aTapbackIsAnAddReactionIntent() async throws {
        let (store, source) = await onlineStore((1...3).map { Fixture2.message(Seq($0), them, "Line \($0)") })
        let (p, _) = Fixture2.projection(store: store)
        p.start()
        p.react(PartRef(messageId: "k2", partIndex: 0), .tapback("like"))
        var sent = await source.submitted
        for _ in 0..<400 where sent.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
            sent = await source.submitted
        }
        #expect(sent.map(\.op) == [.addReaction(message: MessageID("msg_2"), conversation: Fixture2.id,
                                                reaction: .tapback(.like), partIndex: 0)])
        p.stop()
        store.stop()
    }

    @Test func aReceiveKeepsTheFirstVisibleRowWhereItWasWhenScrolledUp() throws {
        let (p, c) = Fixture2.projection()
        c.host.layoutSubtreeIfNeeded()
        let items = Fixture2.history(80)
        p.apply(items: items, summary: Fixture2.summary(lastSeq: 80), typing: [], hasOlder: true)
        c.host.layoutSubtreeIfNeeded()
        let demo = try #require(c.demo)
        demo.collection.contentOffset.y = demo.pinnedOffset - 900
        demo.userScrolled()
        #expect(!c.store.state.ui.scroll.pinnedToBottom)
        let before = try #require(demo.anchorProbe)
        p.apply(items: items + [Fixture2.item(81, them, "While you read")], summary: Fixture2.summary(lastSeq: 81), typing: [], hasOlder: true)
        let after = try #require(demo.anchorProbe)
        #expect(after.key == before.key)
        #expect(abs(after.y - before.y) < 0.5)
        // An older page above keeps it too.
        let older = (61...80).map { Fixture2.item(Seq($0 - 60), them, "Older \($0)", key: "o\($0)") }
        p.apply(items: older + items + [Fixture2.item(81, them, "While you read")], summary: Fixture2.summary(lastSeq: 81), typing: [], hasOlder: false)
        let paged = try #require(demo.anchorProbe)
        #expect(paged.key == before.key)
        #expect(abs(paged.y - before.y) < 0.5)
    }

    /// Lawrence (R76 port): no band, border or inset card around the Home
    /// transcript. The header is the blurred transcript with the avatar and
    /// the glass name pill only; the pane has no window border or corners.
    @Test func thePaneHasNoBandBorderOrCorners() throws {
        let (p, c) = Fixture2.projection()
        p.apply(items: Fixture2.history(5), summary: Fixture2.summary(lastSeq: 5), typing: [], hasOlder: false)
        c.host.layoutSubtreeIfNeeded()
        let demo = try #require(c.demo)
        #expect(demo.chrome.isHidden, "ChromeView strokes the window's rounded border")
        #expect(demo.layer.cornerRadius == 0)
        #expect(demo.header.isHidden, "the drawn capture header (hairline, pill) stays hidden")
        #expect(c.host.layer?.backgroundColor == nil)
        // Glass in the header area: only the name pill (no full-width band).
        func glass(_ v: NSView) -> [NSView] { (v is NSGlassEffectView ? [v] : []) + v.subviews.flatMap(glass) }
        let header = glass(c.host).filter { $0.convert($0.bounds, to: c.host).minY < Fixture.headerHeight }
        #expect(header.isEmpty, "no glass band under the header: \(header)")
        #expect(c.host.headerBackdrop.frame.height == Fixture.headerHeight)
        #expect(c.host.headerBackdrop.layer?.borderWidth == 0)
    }
}

