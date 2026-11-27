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
        let first = #"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"paced"}}"#
        guard case .pageRefused = AgentTurnStateFeed.Message(line: Data(first.utf8)) else {
            Issue.record("a refused first page is not read as refused")
            return
        }
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
