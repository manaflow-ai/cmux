import Foundation
import Testing
@testable import CmuxHomeCore

@Suite struct MirrorAndIntentLogTests {
    let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
    let chief = Participant(id: ParticipantID("agent_chief"), kind: .agent, displayName: "Chief", agentClass: .chief)
    let conv = ConversationID("conv_a")

    func summary(lastSeq: Seq = 0, rev: Revision = 0, pin: Int? = nil) -> ConversationSummary {
        ConversationSummary(id: conv, participants: [me, chief], lastSeq: lastSeq, rev: rev,
                            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), pinRank: pin)
    }

    func message(_ seq: Seq, key: String, author: ParticipantID? = nil) -> Message {
        Message(id: MessageID("m\(seq)"), conversation: conv, seq: seq, clientMessageID: IdempotencyKey(key),
                author: author ?? me.id, parts: [.text("t\(seq)")], createdAt: Date(timeIntervalSince1970: Double(seq)))
    }

    @Test func echoSettlesASendAndKeepsItsID() {
        var mirror = HomeMirror()
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary()], rev: 1))
        mirror.apply(page: ConversationPage(conversation: summary(), messages: []))
        var log = IntentLog()
        let intent = HomeIntent(key: IdempotencyKey("k1"), op: .sendMessage(conversation: conv, parts: [.text("hi")]))
        log.append(intent)
        let before = TranscriptDerivation.items(window: mirror.windows[conv], pending: log.sends(in: conv), me: me.id)
        #expect(before.map(\.id) == [IdempotencyKey("k1")])
        #expect(before.first?.delivery == .sending)

        #expect(mirror.apply(.message(message(1, key: "k1"), rev: 1)) == .applied)
        #expect(log.settle(against: mirror) == [IdempotencyKey("k1")])
        let after = TranscriptDerivation.items(window: mirror.windows[conv], pending: log.sends(in: conv), me: me.id)
        #expect(after.map(\.id) == [IdempotencyKey("k1")])
        #expect(after.first?.delivery == .committed)
    }

    @Test func duplicateAndStaleEventsAreIgnoredAndGapsReported() {
        var mirror = HomeMirror()
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary()], rev: 1))
        mirror.apply(page: ConversationPage(conversation: summary(), messages: []))
        #expect(mirror.apply(.message(message(1, key: "a"), rev: 1)) == .applied)
        #expect(mirror.apply(.message(message(1, key: "a"), rev: 1)) == .ignoredStale)
        #expect(mirror.apply(.message(message(3, key: "c"), rev: 3)) == .gap(.conversation(conv)))
    }

    @Test func acknowledgedPinLeavesWhenTheInboxRevisionArrives() {
        var mirror = HomeMirror()
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary()], rev: 4))
        var log = IntentLog()
        log.append(HomeIntent(key: IdempotencyKey("p"), op: .setPinned(conversation: conv, rank: 1)))
        #expect(InboxOrdering.rows(mirror: mirror, log: log).first?.isPinned == true)
        log.acknowledge(IdempotencyKey("p"), rev: 5)
        #expect(log.settle(against: mirror).isEmpty)
        mirror.apply(.conversationChanged(summary(pin: 1), stream: .inbox, rev: 5))
        #expect(log.settle(against: mirror) == [IdempotencyKey("p")])
        #expect(InboxOrdering.rows(mirror: mirror, log: log).first?.isPinned == true)
    }

    @Test func disconnectMarksInFlightUnconfirmedAndReconnectResendsInOrder() {
        var log = IntentLog()
        let a = HomeIntent(key: IdempotencyKey("a"), op: .sendMessage(conversation: conv, parts: [.text("1")]))
        let b = HomeIntent(key: IdempotencyKey("b"), op: .sendMessage(conversation: conv, parts: [.text("2")]))
        log.append(a)
        log.append(b)
        log.acknowledge(IdempotencyKey("a"), rev: 9)
        log.markDisconnected()
        #expect(log.takeResends() == [b])
        #expect(log.takeResends().isEmpty)
    }

    @Test func pinnedRowsComeFirstThenNewest() {
        let base = Date(timeIntervalSince1970: 1_000)
        func row(_ id: String, pin: Int?, at offset: Double) -> InboxRow {
            var s = summary(pin: pin)
            s = ConversationSummary(id: ConversationID(id), participants: s.participants, createdAt: base,
                                    updatedAt: base.addingTimeInterval(offset), pinRank: pin)
            return InboxRow(summary: s, kind: .direct, title: id, preview: "", previewAuthor: nil,
                            timestamp: s.updatedAt, unread: 0, isPinned: pin != nil, isSending: false,
                            hasFailedSend: false, isTyping: false)
        }
        let ordered = InboxOrdering.ordered([row("old", pin: nil, at: 1), row("chief", pin: 0, at: 0),
                                             row("new", pin: nil, at: 9), row("p2", pin: 2, at: 99)])
        #expect(ordered.map(\.title) == ["chief", "p2", "new", "old"])
    }

    /// Seeded property check (invariant 4, projection convergence): random
    /// duplicated and reordered delivery of committed events, with refetch on
    /// every reported gap, ends with mirror == owner once the log is empty.
    @Test(arguments: 0..<200)
    func mirrorConvergesUnderDuplicatesAndReordering(seed: Int) {
        var rng = SplitMix(seed: UInt64(seed))
        let count = Int(rng.next() % 12) + 1
        let owner = (1...count).map { message(Seq($0), key: "k\($0)") }
        var deliveries: [Message] = owner
        for _ in 0..<Int(rng.next() % 6) { deliveries.append(owner[Int(rng.next() % UInt64(count))]) }
        for index in deliveries.indices.reversed() where rng.next() % 3 == 0 {
            deliveries.swapAt(index, Int(rng.next() % UInt64(deliveries.count)))
        }
        var mirror = HomeMirror()
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary()], rev: 1))
        mirror.apply(page: ConversationPage(conversation: summary(), messages: []))
        for message in deliveries {
            if case .gap = mirror.apply(.message(message, rev: message.seq)) {
                // Refetch the tail from the owner, as HomeStore does.
                let upTo = owner.filter { $0.seq <= mirror.revision(of: .conversation(conv)) }
                mirror.apply(page: ConversationPage(conversation: summary(lastSeq: Seq(upTo.count), rev: Seq(upTo.count)), messages: upTo))
            }
        }
        let window = mirror.windows[conv]?.messages ?? []
        let expected = owner.filter { $0.seq <= window.last?.seq ?? 0 }
        #expect(window == expected, "seed \(seed)")
        #expect(window.last?.seq == Seq(count), "seed \(seed)")
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
