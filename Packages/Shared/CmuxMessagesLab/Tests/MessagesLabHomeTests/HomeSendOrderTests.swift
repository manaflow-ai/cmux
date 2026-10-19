import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A message I send while the Chief's reply streams goes below the reply text
/// already on screen, in send order, and nothing moves when the reply posts
/// (ProjectionCore+Freeze).
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

    /// The texts the projection shows, oldest first (streams last, as RowBuilder draws them).
    static func shown(_ store: Store) -> [String] {
        (store.state.conversation.messages + store.state.ui.streams.filter { !$0.parts.isEmpty }.map(\.message)).map { m in
            m.parts.compactMap { if case let .text(t, _) = $0 { t } else { nil } }.joined()
        }
    }

    /// The Chief streams "Started the agent.", I send twice, it streams on and posts its reply.
    @Test func mySendsStayBelowTheReplyTextAlreadyShown() throws {
        var core = ProjectionCore(me: Self.me)
        let base = [Self.item("h1", 1, Self.me, "Find Cmd+P")]
        let (conv, w) = core.install(Self.id, items: core.arrange(base), summary: Self.summary)
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        store.responder = nil
        let sid = ProjectionCore.streamID(Self.turn)
        // The reply's stream, as `stream(_:state:)` begins it.
        store.dispatch(.streamBegin(sid, sender: Self.chief.rawValue, format: nil))
        store.dispatch(.streamSet(sid, text: "Started the agent.", parts: nil, seq: 1))
        core.shownStream = ShownStream(turn: Self.turn, author: Self.chief, text: "Started the agent.", seq: 1, full: "Started the agent.")
        #expect(Self.shown(store) == ["Find Cmd+P", "Started the agent."])

        // My send: the shown text freezes in place, my bubble goes below it.
        let k1 = IdempotencyKey("send_1")
        for a in core.freezeStream(before: k1, in: store.state) { store.dispatch(a) }
        store.dispatch(.setDraft("There's a bug here"))
        store.dispatch(.send)
        let recordedk1 = core.recordSend(k1, in: store.state)
        #expect(recordedk1)
        #expect(Self.shown(store) == ["Find Cmd+P", "Started the agent.", "There's a bug here"])

        // HomeStore lists my send; nothing moves, nothing rebuilds.
        var items = base + [Self.item(k1.rawValue, nil, Self.me, "There's a bug here", .sending)]
        var d = core.step(items: core.arrange(items), summary: Self.summary)
        #expect(!d.rebuild)
        d.actions.forEach(store.dispatch)
        #expect(Self.shown(store) == ["Find Cmd+P", "Started the agent.", "There's a bug here"])

        // The reply goes on: only what comes after the frozen text streams, below my send.
        #expect(core.streamText(turn: Self.turn, full: "Started the agent.\n\nIt runs on the builder.") == "\n\nIt runs on the builder.")
        store.dispatch(.streamBegin(sid, sender: Self.chief.rawValue, format: nil))
        store.dispatch(.streamSet(sid, text: "It runs on the builder.", parts: nil, seq: 1))
        core.shownStream = ShownStream(turn: Self.turn, author: Self.chief, text: "It runs on the builder.", seq: 1,
                                       full: "Started the agent.\n\nIt runs on the builder.")

        // A second send while that streams: its text freezes too, my bubble is the newest again.
        let k2 = IdempotencyKey("send_2")
        for a in core.freezeStream(before: k2, in: store.state) { store.dispatch(a) }
        store.dispatch(.setDraft("Also check Enter"))
        store.dispatch(.send)
        let recordedk2 = core.recordSend(k2, in: store.state)
        #expect(recordedk2)
        #expect(Self.shown(store) == ["Find Cmd+P", "Started the agent.", "There's a bug here", "It runs on the builder.", "Also check Enter"])

        // The owner posts the whole reply after both sends (its seq is newer): only the rest shows, at the bottom.
        items = base + [Self.item(k1.rawValue, 2, Self.me, "There's a bug here"), Self.item(k2.rawValue, 3, Self.me, "Also check Enter"),
                        Self.item(Self.turn.rawValue, 4, Self.chief, "Started the agent.\n\nIt runs on the builder.\n\nDone.")]
        d = core.step(items: core.arrange(items), summary: Self.summary)
        #expect(!d.rebuild)
        d.actions.forEach(store.dispatch)
        #expect(Self.shown(store) == ["Find Cmd+P", "Started the agent.", "There's a bug here", "It runs on the builder.",
                                      "Also check Enter", "Done."])
    }

    @Test func aReplyThatSaysNothingMoreLeavesOnlyItsPieces() {
        var core = ProjectionCore(me: Self.me)
        let base = [Self.item("h1", 1, Self.me, "Hi")]
        let (conv, w) = core.install(Self.id, items: base, summary: Self.summary)
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        core.shownStream = ShownStream(turn: Self.turn, author: Self.chief, text: "Hello.", seq: 1, full: "Hello.")
        _ = core.freezeStream(before: IdempotencyKey("s"), in: store.state)
        let arranged = core.arrange(base + [Self.item("s", 2, Self.me, "Next"), Self.item(Self.turn.rawValue, 3, Self.chief, "Hello.")])
        #expect(arranged.map(\.key.rawValue) == ["h1", "turn_1#1", "s"])
    }

    @Test func aReplyThatChangedItsTextDropsThePieces() {
        var core = ProjectionCore(me: Self.me)
        let base = [Self.item("h1", 1, Self.me, "Hi")]
        let (conv, w) = core.install(Self.id, items: base, summary: Self.summary)
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        core.shownStream = ShownStream(turn: Self.turn, author: Self.chief, text: "Draft one", seq: 1, full: "Draft one")
        _ = core.freezeStream(before: IdempotencyKey("s"), in: store.state)
        let arranged = core.arrange(base + [Self.item("s", 2, Self.me, "Next"), Self.item(Self.turn.rawValue, 3, Self.chief, "Another text")])
        #expect(arranged.map(\.key.rawValue) == ["h1", "s", "turn_1"])
        #expect(core.frozen.isEmpty)
    }

    @Test func noStreamNoFreeze() {
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(Self.id, items: [], summary: Self.summary)
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        let actions = core.freezeStream(before: IdempotencyKey("s"), in: store.state)
        #expect(actions.isEmpty)
        #expect(core.frozen.isEmpty)
    }
}
