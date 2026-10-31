import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The exact case u2891 saw on NIGHTLY 4803cf844394: the Chief's reply was cut
/// mid-word around a message the user sent while it streamed ("...deletes the
/// old switching code an" / the user's bubble / "d writes it again..."). The
/// real view (`MessagesLabHomeView`) over a real `HomeStore` on the mock owner,
/// in an offscreen window; the stream comes as HomeStore's draft, the send goes
/// through `HomeProjection.send`, as Return does. The rule: the reply is always
/// one bubble, placed before or after my message, never split mid-word.
@MainActor @Suite(.serialized) struct HomeMidStreamSendTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")
    static let head = "The new path deletes the old switching code an"
    static let tail = "d writes it again in one place, so a tab switch reads one state."
    static let mine = "Wait, keep the old path behind a flag for now"

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    /// The bubbles the transcript shows, oldest first: author and text (streams last, as RowBuilder draws them).
    private static func bubbles(_ view: MessagesLabHomeView) -> [(sender: String, text: String)] {
        guard let s = view.controller.store?.state else { return [] }
        let streams = s.ui.streams.filter { !$0.parts.isEmpty }.map(\.message)
        return (s.conversation.messages + streams).map { m in
            (m.senderId, m.parts.compactMap { if case let .text(t, _) = $0 { t } else { nil } }.joined())
        }
    }

    /// The reply shows whole in exactly one bubble, and no other bubble holds a piece of it.
    private static func expectOneReply(_ view: MessagesLabHomeView, _ reply: String, chief: ParticipantID, _ step: String, sent: Bool = true) {
        let shown = bubbles(view)
        let holding = shown.filter { $0.text.contains(head) || $0.text.contains(tail) || $0.text.hasPrefix("d writes") }
        #expect(holding.count == 1, "\(step): the reply shows in \(holding.count) bubbles: \(holding.map(\.text))")
        #expect(holding.first?.text == reply, "\(step): the reply bubble reads \(holding.first?.text ?? "nothing")")
        #expect(holding.first?.sender == chief.rawValue, "\(step): the reply bubble is not the Chief's")
        let mineAt = shown.lastIndex { $0.text == mine }
        #expect((mineAt != nil) == sent, "\(step): my message is \(mineAt == nil ? "not shown" : "shown before its send")")
        // Before or after my message, never on both sides of it.
        if let mineAt {
            let before = shown[..<mineAt].contains { $0.text.contains(head) || $0.text.contains(tail) }
            let after = shown[(mineAt + 1)...].contains { $0.text.contains(head) || $0.text.contains(tail) }
            #expect(!(before && after), "\(step): the reply shows on both sides of my message")
        }
    }

    @Test func aSendWhileTheReplyStreamsKeepsTheReplyOneBubble() async throws {
        // The mock owner's own answer to my send comes after the test ends.
        let options = MockHomeSource.Options(chiefHistory: 300, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        defer { store.stop() }
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let chief = try #require(store.transcript(for: Self.conversation).first { $0.author != me }?.author)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake(), replies: .streaming)
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let projection = view.projection
        // The display frames: work the view schedules for the next frame runs at each frame's start
        // (an offscreen window has no display link; the stream commits once per frame, HomeStreamPacer).
        var pending: [() -> Void] = []
        view.controller.nextFrame = { pending.append($0) }
        func frame() {
            let due = pending
            pending.removeAll()
            for f in due { f() }
            projection.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }

        // The reply streams up to the cut, mid-word.
        let turn = IdempotencyKey("turn_u2891")
        var draft = HomeTurnDraft(participant: chief, turn: turn)
        var text = ""
        for word in Self.head.split(separator: " ", omittingEmptySubsequences: false) {
            text += (text.isEmpty ? "" : " ") + word
            draft.segments[0] = text
            draft.lastSeq += 1
            store.showDraft(draft, turn: turn, author: chief, in: Self.conversation)
            frame()
        }
        Self.expectOneReply(view, Self.head, chief: chief, "before the send", sent: false)

        // I send while it streams (Return).
        let seqBefore = store.summary(Self.conversation)?.lastSeq ?? 0
        view.controller.dispatch(.setDraft(Self.mine))
        #expect(projection.send() == nil, "the send was refused")
        frame()
        Self.expectOneReply(view, Self.head, chief: chief, "at the send")
        await until { (store.summary(Self.conversation)?.lastSeq ?? 0) > seqBefore }
        frame()
        Self.expectOneReply(view, Self.head, chief: chief, "my send committed")

        // The reply goes on from the middle of the word.
        let whole = Self.head + Self.tail
        draft.segments[0] = whole
        draft.lastSeq += 1
        store.showDraft(draft, turn: turn, author: chief, in: Self.conversation)
        frame()
        Self.expectOneReply(view, whole, chief: chief, "streaming after the send")

        // The owner posts the reply after my send; the stream ends in the same change.
        let summary = try #require(store.summary(Self.conversation))
        let rev = store.mirror.revision(of: .conversation(Self.conversation)) + 1
        store.showDraft(nil, turn: turn, author: chief, in: Self.conversation)
        store.handle(.message(CmuxHomeCore.Message(id: MessageID("msg_u2891"), conversation: Self.conversation, seq: summary.lastSeq + 1,
                                      clientMessageID: turn, author: chief, parts: [.text(whole)], createdAt: Date()), rev: rev))
        frame()
        Self.expectOneReply(view, whole, chief: chief, "posted")
        let shown = Self.bubbles(view)
        let mineAt = try #require(shown.lastIndex { $0.text == Self.mine })
        let replyAt = try #require(shown.lastIndex { $0.text == whole })
        #expect(replyAt > mineAt, "the posted reply is older than my send in the owner's order")
        #expect(view.controller.store?.state.ui.streams.isEmpty == true, "a stream is left after the post")
    }
}
