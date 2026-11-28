import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

@MainActor
@Suite struct IntentMappingTests {
    private func loaded(_ count: Int = 4) -> (HomeController, [Message]) {
        let c = Fixtures.controller()
        let messages = Fixtures.conversation(count)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        return (c, messages)
    }

    /// Return sends the trimmed draft as one text part with a fresh key and
    /// empties the field; nothing else is sent.
    @Test func sendMapsToSendMessage() throws {
        let (c, _) = loaded()
        var emitted: [HomeIntent] = []
        c.onIntent = { emitted.append($0) }
        c.handle(.insertText("  hello\n", replacing: nil))
        #expect(emitted.isEmpty, "typing sends nothing")
        let intent = try #require(c.handle(.send))
        #expect(intent.op == .sendMessage(conversation: Fixtures.conversation, parts: [.text("hello")]))
        #expect(emitted == [intent])
        #expect(c.draft.isEmpty)
        #expect(c.handle(.send) == nil, "an empty draft sends nothing")
        c.handle(.insertText(" \n ", replacing: nil))
        #expect(c.handle(.send) == nil, "whitespace sends nothing")
        #expect(emitted.count == 1)
    }

    @Test func eachSendGetsItsOwnKey() throws {
        let (c, _) = loaded()
        c.handle(.insertText("one", replacing: nil))
        let a = try #require(c.handle(.send))
        c.handle(.insertText("two", replacing: nil))
        let b = try #require(c.handle(.send))
        #expect(a.key != b.key)
    }

    /// With IME marked text, Return commits the composition instead of sending.
    @Test func returnCommitsMarkedTextFirst() {
        let (c, _) = loaded()
        c.handle(.setMarkedText("にほ", selected: NSRange(location: 2, length: 0), replacing: nil))
        #expect(c.markedRange == NSRange(location: 0, length: 2))
        #expect(c.handle(.send) == nil)
        #expect(c.markedRange == nil)
        #expect(c.draft == "にほ")
    }

    /// The owner's echo of my send (same key) becomes the bubble the morph lands on.
    @Test func echoOfMySendStartsTheMorph() throws {
        let (c, messages) = loaded()
        c.handle(.insertText("hello", replacing: nil))
        let intent = try #require(c.handle(.send))
        let pending = Fixtures.items(messages, pending: [PendingIntent(intent: intent)])
        c.update(items: pending, summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(c.scene.morphs.count == 1)
        #expect(c.pendingSend == nil)
        #expect(c.scene.model.index["part:\(intent.key.rawValue):0"] != nil)
    }

    /// Reduce Motion: no movement, the change cross-fades instead.
    @Test func reduceMotionCrossFadesInsteadOfMoving() throws {
        let (c, messages) = loaded()
        c.reduceMotion = true
        c.handle(.insertText("hello", replacing: nil))
        let intent = try #require(c.handle(.send))
        c.update(items: Fixtures.items(messages, pending: [PendingIntent(intent: intent)]), summary: Fixtures.summary(),
                 typing: [], hasOlder: false)
        #expect(c.scene.morphs.isEmpty)
        #expect(c.scene.crossFade != nil)
        #expect(c.scene.ledger.isEmpty)
    }

    /// The owner refused the send before logging it: the text comes back.
    @Test func refusedSendRestoresTheDraft() throws {
        let (c, _) = loaded()
        c.handle(.insertText("keep me", replacing: nil))
        let intent = try #require(c.handle(.send))
        #expect(c.draft.isEmpty)
        c.restoreDraft(for: intent.key)
        #expect(c.draft == "keep me")
        c.restoreDraft(for: intent.key)
        #expect(c.draft == "keep me")
    }

    /// The read cursor advances only while the newest row is on screen and the user sees it.
    @Test func readCursorFollowsWhatTheUserSees() {
        let (c, messages) = loaded(60)
        var emitted: [HomeOp] = []
        c.onIntent = { emitted.append($0.op) }
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [Fixtures.chief], hasOlder: false)
        #expect(emitted.isEmpty, "not visible to the user yet")
        c.isVisibleToUser = true
        #expect(emitted == [.setReadCursor(conversation: Fixtures.conversation, seq: 60)])
        c.handle(.scroll(deltaY: 400, phase: .changed, momentum: .none))
        let more = messages + [Fixtures.message(61, Fixtures.chief, "More.")]
        c.update(items: Fixtures.items(more), summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(emitted.count == 1, "scrolled up: not read")
        c.handle(.scroll(deltaY: -10_000, phase: .changed, momentum: .none))
        #expect(emitted.last == .setReadCursor(conversation: Fixtures.conversation, seq: 61))
        c.update(items: Fixtures.items(more), summary: Fixtures.summary(read: [Fixtures.me: 61]), typing: [], hasOlder: false)
        #expect(emitted.count == 2, "no repeat once the owner has it")
    }

    @Test func classifiesChanges() {
        let me = Fixtures.me
        let base = Fixtures.items(Fixtures.conversation(6, firstSeq: 11))
        func classify(_ new: [TranscriptItem], typing: (Bool, Bool) = (false, false), read: (Seq?, Seq?) = (nil, nil)) -> TranscriptChange {
            TranscriptChange.classify(old: base, new: new, me: me, typing: typing, read: read)
        }
        #expect(TranscriptChange.classify(old: [], new: base, me: me, typing: (false, false), read: (nil, nil)) == .initial)
        #expect(classify(Fixtures.items(Fixtures.conversation(16, firstSeq: 1))) == .prepend)
        let mine = Fixtures.items(Fixtures.conversation(6, firstSeq: 11) + [Fixtures.message(17, me, "mine")])
        #expect(classify(mine) == .send(IdempotencyKey("key_17")))
        let theirs = Fixtures.items(Fixtures.conversation(6, firstSeq: 11) + [Fixtures.message(17, Fixtures.chief, "theirs")])
        #expect(classify(theirs) == .receive)
        #expect(classify(base, typing: (false, true)) == .typing(true))
        #expect(classify(base, read: (nil, 12)) == .read)
        #expect(classify(base) == .other)
        let sending = PendingIntent(intent: HomeIntent(key: IdempotencyKey("key_17"),
                                                       op: .sendMessage(conversation: Fixtures.conversation, parts: [.text("mine")])))
        let before = Fixtures.items(Fixtures.conversation(6, firstSeq: 11), pending: [sending])
        #expect(TranscriptChange.classify(old: before, new: mine, me: me, typing: (false, false), read: (nil, nil)) == .delivery)
    }

    @Test func accessibilityListsRowsThenTheField() {
        let (c, _) = loaded()
        c.handle(.insertText("draft", replacing: nil))
        let items = c.accessibilityItems()
        #expect(items.last?.role == .textArea)
        #expect(items.last?.value == "draft")
        let parts = items.filter { $0.id.hasPrefix("part:") }
        #expect(parts.count == 4)
        #expect(parts.contains { $0.value == HomeStrings.fromMe })
        #expect(parts.contains { $0.value == HomeStrings.from("Chief") })
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.frame.minY <= $1.frame.minY })
    }
}
