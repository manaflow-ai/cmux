@testable import CmuxNextAgentLanes
import CmuxNextBridge
import Foundation
import Testing

/// Leo (2026-11-18): "stay awake for local agents, and ignore other ma[chines']". This Mac's
/// acpmux lists its peers' sessions too, so with about 30 machines one of them was always working
/// and a plugged-in Mac never slept. Only this Mac's sessions keep it awake (`hasWorkingSession`).
@MainActor @Suite
struct KeepAwakeLocalAgentsTests {
    static func message(_ line: String) throws -> AgentTurnStateFeed.Message {
        try #require(AgentTurnStateFeed.Message(line: Data(line.utf8)))
    }

    /// A `_acpmux/session_changed` of `session`, as peer `peer`'s row when `peer` is given.
    static func change(_ session: String, indicator: String, peer: String? = nil) throws -> AgentTurnStateFeed.Message {
        let peerField = peer.map { #","peer":"\#($0)""# } ?? ""
        return try message(#"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"\#(session)"\#(peerField),"session":{"sessionId":"\#(session)","indicator":"\#(indicator)"\#(peerField)}}}"#)
    }

    static func feed(_ turns: AgentTurnStateStore) -> AgentTurnStateFeed {
        AgentTurnStateFeed(socketPath: "/nonexistent/keep-awake-local.sock", turns: turns, lanes: AgentLaneStore())
    }

    @Test func anotherMachinesWorkingChatOnAWatchPageDoesNotCount() throws {
        let turns = AgentTurnStateStore()
        let feed = Self.feed(turns)
        feed.handle(try Self.message(#"{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"peer-s1","indicator":"working","peer":"lab"},{"sessionId":"peer-s2","indicator":"working","peer":"lab","stale":true},{"sessionId":"local-s1","indicator":"idle"}]}}"#))
        #expect(!turns.hasWorkingSession, "other machines' working chats kept this Mac awake")
        feed.handle(try Self.message(#"{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"peer-s1","indicator":"working","peer":"lab"},{"sessionId":"local-s1","indicator":"working"}]}}"#))
        #expect(turns.hasWorkingSession, "this Mac's working chat did not keep it awake")
    }

    @Test func pushesCountOnlyThisMacsTurns() throws {
        let turns = AgentTurnStateStore()
        let feed = Self.feed(turns)
        feed.handle(try Self.message(#"{"jsonrpc":"2.0","id":2,"result":{"sessions":[]}}"#))
        feed.handle(try Self.change("peer-s1", indicator: "working", peer: "lab"))
        #expect(!turns.hasWorkingSession, "a peer's turn kept this Mac awake")
        feed.handle(try Self.change("local-s1", indicator: "working"))
        #expect(turns.hasWorkingSession, "this Mac's turn did not keep it awake")
        feed.handle(try Self.change("local-s1", indicator: "idle"))
        #expect(!turns.hasWorkingSession, "the hold stayed after this Mac's turn ended")
        feed.handle(try Self.change("peer-s1", indicator: "idle", peer: "lab"))
        feed.handle(try Self.change("peer-s1", indicator: "working", peer: "lab"))
        #expect(!turns.hasWorkingSession, "a peer's next turn kept this Mac awake")
    }
}
