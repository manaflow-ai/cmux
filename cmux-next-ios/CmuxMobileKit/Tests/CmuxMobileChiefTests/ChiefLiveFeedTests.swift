import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

@Suite @MainActor struct ChiefLiveFeedTests {
    @Test func burstPublishesOnlyTheNewestStateAndThenEnds() async {
        let feed = ChiefLiveFeed()
        let (stream, continuation) = AsyncStream<ChiefLive?>.makeStream()
        feed.observe { continuation.yield($0) }
        var events = stream.makeAsyncIterator()
        _ = await events.next() // Initial nil.
        for index in 0..<1_000 {
            feed.update(ChiefLive(key: "run", text: "token \(index)"))
        }
        let latest = await events.next() ?? nil
        #expect(latest?.text == "token 999")
        feed.update(nil)
        let ended = await events.next() ?? nil
        #expect(ended == nil)
        continuation.finish()
    }

    @Test func endingDuringABurstNeverPublishesStaleText() async {
        let feed = ChiefLiveFeed()
        let (stream, continuation) = AsyncStream<ChiefLive?>.makeStream()
        feed.observe { continuation.yield($0) }
        var events = stream.makeAsyncIterator()
        _ = await events.next()
        feed.update(ChiefLive(key: "run", text: "unfinished"))
        feed.update(nil)
        let ended = await events.next() ?? nil
        #expect(ended == nil)
        continuation.finish()
    }

    @Test(arguments: ["agent_mux:chief-reply:run-7", "chief-reply-d:agent_mux:run-7:0", "chief-reply:agent_mux:run-7:2"])
    func aReplyThatArrivesBeforeTheBatchedLiveCallbackMatchesItsRun(clientID: String) throws {
        var state = ChiefLiveState(conversation: "conversation-1")
        #expect(state.delta([
            "conversation": "conversation-1", "author": "agent_mux", "run": "run-7",
            "step": "talk:0", "seq": 0, "text": "answer"
        ]) == .changed)
        let live = try #require(state.current)
        let reply = ConversationMessage(
            id: "reply", seq: 7, clientMessageID: clientID,
            senderID: "agent_mux", sentAt: Date(), text: "answer"
        )
        #expect(ChiefSession.liveReplyMatches(live, message: reply))
        var otherReply = reply
        otherReply.senderID = "agent_other"
        #expect(!ChiefSession.liveReplyMatches(live, message: otherReply))
        otherReply = reply
        otherReply.clientMessageID = clientID.replacingOccurrences(of: "run-7", with: "run-70")
        #expect(!ChiefSession.liveReplyMatches(live, message: otherReply))
        otherReply.clientMessageID = clientID.replacingOccurrences(of: "agent_mux", with: "agent_mux_other")
        #expect(!ChiefSession.liveReplyMatches(live, message: otherReply))
    }

    @Test(arguments: ["chief-reply-d:agent_mux:run-7:0", "chief-reply:agent_mux:run-7:2"])
    func aDelayedLiveReplyStaysHiddenAfterTheNextUserMessage(clientID: String) async throws {
        let backend = LiveReplyBackend()
        let session = ChiefSession(backend: backend, outbox: ChiefOutbox(file: nil))
        defer { session.store.stop() }
        session.isVisible = true
        try await waitUntil("initial history") { session.store.hasLoadedNewest }
        let reply = ConversationMessage(
            id: "reply", seq: 1, clientMessageID: clientID,
            senderID: "agent_mux", sentAt: Date(), text: "answer"
        )
        backend.continuation.yield(.message(reply, eventSeq: 1))
        try await waitUntil("committed reply") { session.lastMessage?.id == "reply" }
        let live = ChiefLive(key: "conversation-1\u{0}agent_mux\u{0}run-7", step: "talk:0", text: "answer")
        session.acceptLive(live)
        #expect(session.shownLive?.text == "")
        backend.continuation.yield(.message(ConversationMessage(
            id: "follow-up", seq: 2, clientMessageID: "user-follow-up",
            senderID: "user_local", sentAt: Date(), text: "continue"
        ), eventSeq: 2))
        try await waitUntil("user follow-up") { session.lastMessage?.id == "follow-up" }
        #expect(session.shownLive?.text == "")
        session.acceptLive(live)
        #expect(session.shownLive?.text == "")
        session.acceptLive(nil)
        #expect(session.shownLive == nil)
    }
}

private final class LiveReplyBackend: ConversationBackend, Sendable {
    let stream: AsyncStream<ConversationBackendEvent>
    let continuation: AsyncStream<ConversationBackendEvent>.Continuation
    private let unavailable = ChiefOfflineBackend()

    init() {
        (stream, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected(info: ChiefIdentity.standard.info(id: "conversation-1"), meID: "user_local", lagged: false))
    }

    func events() -> AsyncStream<ConversationBackendEvent> { stream }
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage { .init(messages: [], hasMore: false) }
    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage { try await unavailable.send(draft) }
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage { try await unavailable.react(messageID: messageID, reaction: reaction) }
    func edit(messageID: String, text: String) async throws -> ConversationMessage { try await unavailable.edit(messageID: messageID, text: text) }
    func unsend(messageID: String) async throws -> ConversationMessage { try await unavailable.unsend(messageID: messageID) }
    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment { try await unavailable.uploadImage(data, mimeType: mimeType) }
    func close() { continuation.finish() }
}
