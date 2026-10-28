@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A message I send while the Chief's reply streams never splits that reply
/// (Lawrence 2026-10-19: one reply showed as "I restarted everything th" above
/// his message and "e failed turns dropped…" below it). The rule is the owner's
/// order: the reply posts after my send, so its one streaming bubble stays the
/// newest row, below my send, and the posted reply takes that bubble's place.
/// Each step drives the same `ProjectionCore` calls `HomeProjection` makes
/// (`streams`, `step`, the send) against a real MessagesLab store.
@MainActor @Suite(.serialized) struct HomeSendOrderTests {
    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_chief")
    static let id = ConversationID("conv_order")
    static let turn = IdempotencyKey("turn_1")

    static func date(_ t: Double) -> Date { Replay.base.addingTimeInterval(t) }

    static var summary: ConversationSummary {
        ConversationSummary(id: id, title: "Chief", participants: [
            CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
            CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief),
        ], lastSeq: 1, createdAt: date(-100), updatedAt: date(0))
    }

    static func item(_ key: String, _ seq: Seq?, _ author: ParticipantID, _ text: String, _ delivery: TranscriptItem.Delivery = .committed) -> TranscriptItem {
        TranscriptItem(key: IdempotencyKey(key), seq: seq, author: author, parts: [.text(text)], createdAt: date(Double(seq ?? 9)),
                       delivery: delivery, messageID: seq.map { MessageID("msg_\($0)") })
    }

    /// The running reply as HomeStore's timeline holds it: its whole text so far.
    static func draft(_ text: String) -> [HomeStreamRow] {
        [HomeStreamRow(turn: turn, author: chief, text: text)]
    }

    /// The texts the projection shows, oldest first (streams last, as RowBuilder draws them).
    static func shown(_ store: Store) -> [String] {
        (store.state.conversation.messages + store.state.ui.streams.filter { !$0.parts.isEmpty }.map(\.message)).map { m in
            m.parts.compactMap { if case let .text(t, _) = $0 { t } else { nil } }.joined()
        }
    }

    /// The bubbles that show text by the Chief: one per reply, never a piece of one.
    static func chiefBubbles(_ store: Store) -> Int {
        store.state.conversation.messages.filter { $0.senderId == chief.rawValue }.count
            + store.state.ui.streams.filter { !$0.parts.isEmpty }.count
    }

    /// The Chief streams, I send twice mid-word, it streams on and posts its reply.
    @Test func aSendMidStreamNeverSplitsTheReply() throws {
        var core = ProjectionCore(me: Self.me)
        core.replies = .streaming // the older stream bubble (HomeReplyDisplay)
        let base = [Self.item("h1", 1, Self.me, "Find Cmd+P")]
        let (conv, w) = core.install(Self.id, items: base, summary: Self.summary)
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        store.responder = nil
        func stream(_ text: String) { for a in core.streams(Self.draft(text), state: store.state) { store.dispatch(a) } }
        func send(_ key: IdempotencyKey, _ text: String) -> Bool {
            store.dispatch(.setDraft(text))
            store.dispatch(.send)
            return core.recordSend(key, in: store.state)
        }

        stream("I restarted everything th")
        #expect(Self.shown(store) == ["Find Cmd+P", "I restarted everything th"])

        // My send mid-word: it goes above the running reply, which stays one bubble.
        let k1 = IdempotencyKey("send_1")
        let sent1 = send(k1, "Sentry crashes")
        #expect(sent1)
        #expect(Self.shown(store) == ["Find Cmd+P", "Sentry crashes", "I restarted everything th"])

        // HomeStore lists my send; nothing rebuilds.
        var items = base + [Self.item(k1.rawValue, nil, Self.me, "Sentry crashes", .sending)]
        var d = core.step(items: items, summary: Self.summary)
        #expect(!d.rebuild)
        d.actions.forEach(store.dispatch)

        // The reply goes on in the same bubble, whole: no word is cut.
        stream("I restarted everything the failed turns dropped.")
        #expect(Self.shown(store) == ["Find Cmd+P", "Sentry crashes", "I restarted everything the failed turns dropped."])
        #expect(Self.chiefBubbles(store) == 1)

        // A second send while that streams: still one reply bubble, the newest row.
        let k2 = IdempotencyKey("send_2")
        let sent2 = send(k2, "Up arrow")
        #expect(sent2)
        stream("I restarted everything the failed turns dropped.\n\nNothing is fixed yet.")
        #expect(Self.shown(store) == ["Find Cmd+P", "Sentry crashes", "Up arrow",
                                      "I restarted everything the failed turns dropped.\n\nNothing is fixed yet."])
        #expect(Self.chiefBubbles(store) == 1)

        // The owner posts the whole reply after both sends (its seq is newer): it takes the bubble's place.
        let final = "I restarted everything the failed turns dropped.\n\nNothing is fixed yet.\n\nDone."
        items = base + [Self.item(k1.rawValue, 2, Self.me, "Sentry crashes"), Self.item(k2.rawValue, 3, Self.me, "Up arrow"),
                        Self.item(Self.turn.rawValue, 4, Self.chief, final)]
        d = core.step(items: items, summary: Self.summary)
        #expect(!d.rebuild)
        #expect(d.handOffAt != nil, "the posted reply ends the stream in place, no second receive")
        let cut = d.handOffAt ?? d.actions.count
        let streamed = core.streams([], state: store.state)
        for (i, a) in d.actions.enumerated() {
            if i == cut { streamed.forEach(store.dispatch) }
            store.dispatch(a)
        }
        if cut >= d.actions.count { streamed.forEach(store.dispatch) }
        #expect(Self.shown(store) == ["Find Cmd+P", "Sentry crashes", "Up arrow", final])
        #expect(Self.chiefBubbles(store) == 1)
        #expect(store.state.ui.streams.isEmpty)
    }

    /// Chunks only grow the bubble in order: a late, older `.streamSet` never takes text back.
    @Test func streamChunksApplyInOrder() {
        var core = ProjectionCore(me: Self.me)
        core.replies = .streaming // the older stream bubble (HomeReplyDisplay)
        let (conv, w) = core.install(Self.id, items: [], summary: Self.summary)
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        store.responder = nil
        for text in ["One", "One two", "One two three"] {
            for a in core.streams(Self.draft(text), state: store.state) { store.dispatch(a) }
        }
        let sid = ProjectionCore.streamID(Self.turn)
        store.dispatch(.streamSet(sid, text: "One", parts: nil, seq: 1)) // a stale chunk delivered late
        #expect(store.state.ui.streams.map(\.text) == ["One two three"])
    }
}
