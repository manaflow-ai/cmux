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

    @Test func aReplyThatArrivesBeforeTheBatchedLiveCallbackMatchesItsRun() throws {
        var state = ChiefLiveState(conversation: "conversation-1")
        #expect(state.delta([
            "conversation": "conversation-1", "author": "agent_mux", "run": "run-7",
            "step": "talk:0", "seq": 0, "text": "answer"
        ]) == .changed)
        let live = try #require(state.current)
        let reply = ConversationMessage(
            id: "reply", seq: 7, clientMessageID: "agent_mux:chief-reply:run-7",
            senderID: "agent_mux", sentAt: Date(), text: "answer"
        )
        #expect(ChiefSession.liveReplyMatches(live, message: reply))
        var otherReply = reply
        otherReply.senderID = "agent_other"
        #expect(!ChiefSession.liveReplyMatches(live, message: otherReply))
        otherReply = reply
        otherReply.clientMessageID = "agent_mux:chief-reply:run-8"
        #expect(!ChiefSession.liveReplyMatches(live, message: otherReply))
    }
}
