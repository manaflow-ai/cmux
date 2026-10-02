import Foundation
import Testing
@testable import CmuxHomeCore

/// Regressions for the lane 14 review findings (mirror + intent log).
@Suite struct MirrorReviewRegressionTests {
    let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
    let other = Participant(id: ParticipantID("user_o"), kind: .human, displayName: "O")
    let conv = ConversationID("conv_r")

    func summary(rev: Revision, lastSeq: Seq = 0, pin: Int? = nil) -> ConversationSummary {
        ConversationSummary(id: conv, participants: [me, other], lastSeq: lastSeq, rev: rev,
                            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), pinRank: pin)
    }

    func message(_ seq: Seq) -> Message {
        Message(id: MessageID("m\(seq)"), conversation: conv, seq: seq, clientMessageID: IdempotencyKey("k\(seq)"),
                author: other.id, parts: [.text("t\(seq)")], createdAt: Date(timeIntervalSince1970: Double(seq)))
    }

    @Test func eventsDuringTheFirstPageAreKept() {
        var mirror = HomeMirror()
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary(rev: 2, lastSeq: 2)], rev: 1))
        mirror.beginLoading(conv)
        // Committed while the page (read at rev 2) was in flight.
        #expect(mirror.apply(.message(message(3), rev: 3)) == .applied)
        let outcome = mirror.apply(page: ConversationPage(conversation: summary(rev: 2, lastSeq: 2), messages: [message(1), message(2)]))
        #expect(outcome == .gap(.conversation(conv)))
        #expect(mirror.windows[conv]?.messages.map(\.seq) == [1, 2, 3])
    }

    @Test func conversationEventsDoNotClearInboxPins() {
        var mirror = HomeMirror()
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary(rev: 0, pin: 0)], rev: 1))
        mirror.apply(.conversationChanged(summary(rev: 1, pin: nil), stream: .conversation(conv), rev: 1))
        #expect(mirror.conversations[conv]?.pinRank == 0)
        mirror.apply(.conversationChanged(summary(rev: 1, pin: nil), stream: .inbox, rev: 2))
        #expect(mirror.conversations[conv]?.pinRank == nil)
    }

    @Test func inboxSnapshotDoesNotAdvanceALoadedWindowAndBlocksSettling() {
        var mirror = HomeMirror()
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary(rev: 1, lastSeq: 1)], rev: 1))
        mirror.apply(page: ConversationPage(conversation: summary(rev: 1, lastSeq: 1), messages: [message(1)]))
        var log = IntentLog()
        log.append(HomeIntent(key: IdempotencyKey("r"), op: .setReadCursor(conversation: conv, seq: 1)))
        log.acknowledge(IdempotencyKey("r"), rev: 3)
        let behind = mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary(rev: 3, lastSeq: 2)], rev: 2))
        #expect(behind == [.conversation(conv)])
        #expect(mirror.revision(of: .conversation(conv)) == 1)
        #expect(log.settle(against: mirror).isEmpty)
        mirror.apply(page: ConversationPage(conversation: summary(rev: 3, lastSeq: 2), messages: [message(1), message(2)]))
        #expect(log.settle(against: mirror) == [IdempotencyKey("r")])
    }
}

/// An owner that commits an op but loses the first answer.
actor LosingFirstAnswerSource: HomeSource {
    let inner: MockHomeSource
    private var lost = false
    init(inner: MockHomeSource) { self.inner = inner }
    func events() async -> AsyncStream<HomeEvent> { await inner.events() }
    func inbox() async throws -> InboxSnapshot { try await inner.inbox() }
    func snapshot(of c: ConversationID, tail: Int) async throws -> ConversationPage { try await inner.snapshot(of: c, tail: tail) }
    func history(of c: ConversationID, before s: Seq, limit: Int) async throws -> [Message] { try await inner.history(of: c, before: s, limit: limit) }
    func search(_ q: String, limit: Int) async throws -> [HomeSearchHit] { try await inner.search(q, limit: limit) }
    func resolve(_ c: ContactAddress) async throws -> ContactResolution { try await inner.resolve(c) }
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        let result = try await inner.submit(intent)
        if !lost { lost = true; throw HomeRejection.indeterminate }
        return result
    }
}

@MainActor
@Suite struct StoreReviewRegressionTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
    }

    @Test func lostAnswerIsResentOnceWithTheSameKeyAndApplied() async throws {
        let source = LosingFirstAnswerSource(inner: MockHomeSource(options: .immediate))
        let store = HomeStore(source: source)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        let id = ConversationID("conv_aziz")
        await store.open(id)
        let key = IdempotencyKey("lost-1")
        await #expect(throws: HomeSendState.pendingResend) {
            try await store.perform(.sendMessage(conversation: id, parts: [.text("once")]), key: key)
        }
        await waitUntil { store.log.isEmpty }
        #expect(store.log.isEmpty)
        let page = try await source.snapshot(of: id, tail: 50)
        #expect(page.messages.filter { $0.clientMessageID == key }.count == 1)
        #expect(store.transcript(for: id).filter { $0.id == key }.count == 1)
    }

    @Test func stoppedStoreRefusesOps() async {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        await waitUntil { store.isOnline }
        store.stop()
        await #expect(throws: HomeRejection.ownerUnreachable) {
            try await store.perform(.setMuted(conversation: ConversationID("conv_aziz"), muted: true))
        }
    }
}
