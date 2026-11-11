import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import Foundation
import Testing

/// The turn-state feed reads its list in acpmux's pages and never reconnects to read it again:
/// a refused page is asked again from its cursor, and a burst of one chat's pushes is its newest
/// alone, so the watch's batch does not overflow (each overflow read the whole list again, 31 MB
/// on one Mac, about seven times a minute, 2026-11-11).
struct TurnStateFeedListReadTests {
    @Test func aRefusedPageIsReadAsRefused() {
        let paced = #"{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"session lists are paced","data":{"reason":"list.paced","retryAfterMs":40}}}"#
        guard case .pageRefused = AgentTurnStateFeed.Message(line: Data(paced.utf8)) else {
            Issue.record("a refused page is not read as refused")
            return
        }
        let first = #"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"paced","data":{"reason":"list.paced","retryAfterMs":40}}}"#
        guard case .pageRefused = AgentTurnStateFeed.Message(line: Data(first.utf8)) else {
            Issue.record("a refused first page is not read as refused")
            return
        }
    }

    /// Only acpmux's pacing (`list.paced`) is asked again: any other error of a list page would
    /// fail the same way forever, so it is a failure the watch reconnects on (review F2 on #41204).
    @Test func aListPageErrorThatIsNotPacingIsAFailure() {
        let lines = [
            #"{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"cursor \"x\" is not a cursor"}}"#,
            #"{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"withTools must be a boolean"}}"#,
            #"{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"busy","data":{"reason":"other"}}}"#,
        ]
        for line in lines {
            guard case .pageFailed(let why) = AgentTurnStateFeed.Message(line: Data(line.utf8)) else {
                Issue.record("a list page error that is not pacing is retried: \(line)")
                continue
            }
            #expect(!why.isEmpty)
        }
    }

    /// A drop while the list is being read again is read once more after it lands; before, it was
    /// ignored and the read's end cleared the mark, so the sidebar stayed stale (review F1 on #41204).
    @Test func aDropWhileTheListIsReadAgainReadsItOnceMore() {
        var relist = AgentListResync()
        #expect(relist.overflowed(), "the first drop reads the list")
        #expect(!relist.overflowed(), "a drop while it is out sends no second read at once")
        #expect(!relist.overflowed())
        #expect(relist.listArrived(), "the read lands: one more, for the drops while it was out")
        #expect(!relist.listArrived(), "that one lands: the list is whole")
        #expect(relist.overflowed(), "a later drop reads it again")
        #expect(!relist.listArrived(), "with no drop while it was out, its end is the end")
    }

    @Test func aListThatNoDropAskedForEndsNothing() {
        var relist = AgentListResync()
        #expect(!relist.listArrived(), "the watch's own first list asks for no read again")
        #expect(relist.overflowed())
        #expect(!relist.listArrived())
    }

    @Test func aChatsPushesShareAKeyAndAPurgeHasNone() throws {
        func push(_ session: String, kind: String = "status", peer: String? = nil) throws -> AgentTurnStateFeed.Message {
            var params: [String: Any] = ["sessionId": session, "kind": kind,
                                         "session": ["sessionId": session, "status": "running", "updatedAt": 2]]
            if let peer { params["peer"] = peer }
            let line = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "_acpmux/session_changed", "params": params])
            return try #require(AgentTurnStateFeed.Message(line: line))
        }
        let a1 = AgentTurnStateFeed.Message.key(try push("a"))
        #expect(a1 != nil)
        #expect(AgentTurnStateFeed.Message.key(try push("a")) == a1)
        #expect(AgentTurnStateFeed.Message.key(try push("b")) != a1)
        #expect(AgentTurnStateFeed.Message.key(try push("a", peer: "box")) != a1, "a peer's row of the chat is its own")
        #expect(AgentTurnStateFeed.Message.key(try push("a", kind: "purged")) == nil, "a purge is never replaced")
    }
}
