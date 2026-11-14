import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextBridge
import Foundation
import Testing

/// The turn-state feed keeps its list position across reconnects and, from an acpmux that follows
/// one (`session-list-follow-v1`), reads only the rows changed since, not the whole list (Leo,
/// 2026-11-12: "it's unacceptable to be having so many of these connectivity issues").
@MainActor
struct TurnStateFeedListFollowTests {
    private func message(_ object: [String: Any]) throws -> AgentTurnStateFeed.Message {
        try #require(AgentTurnStateFeed.Message(line: try JSONSerialization.data(withJSONObject: object)))
    }

    private func requests(_ payload: Data) throws -> [[String: Any]] {
        try payload.split(separator: 0x0A).map { try #require(try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }

    private func summary(_ id: String, indicator: String, title: String, peer: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["sessionId": id, "indicator": indicator, "title": title]
        if let peer { row["peer"] = peer }
        return row
    }

    @Test func aReconnectWithACursorSendsOneFollowAndNoListRead() throws {
        var follow = AgentListFollow()
        guard case .initialized(let follows) = try message(["jsonrpc": "2.0", "id": 1, "result": [
            "_meta": ["acpmux": ["capabilities": ["memory-inbox-v1", AgentListFollow.capability]]],
        ]]) else { Issue.record("initialize is not read"); return }
        #expect(follows)
        follow.follows = follows
        follow.listed(seq: 7, epoch: "run-a")
        let sent = try requests(AgentTurnStateFeed.watchRequest(follow.watchParams))
        let methods = sent.compactMap { $0["method"] as? String }
        #expect(methods == ["initialize", "_acpmux/watch"], "no _acpmux/sessions: a follow reads no list")
        let watch = try #require(sent.last?["params"] as? [String: Any])
        #expect((watch["afterSeq"] as? NSNumber)?.uint64Value == 7)
        #expect(watch["listEpoch"] as? String == "run-a")
        #expect(watch["enabled"] as? Bool == true)
    }

    @Test func aFollowReplacesTheRowsItHoldsAndDropsTheGone() throws {
        guard case .page(var held, _) = try message(["jsonrpc": "2.0", "id": 2, "result": [
            "listSeq": 4, "listEpoch": "run-a",
            "sessions": [summary("a", indicator: "working", title: "A"), summary("b", indicator: "input", title: "B"),
                         summary("c", indicator: "working", title: "C", peer: "box"), summary("d", indicator: "input", title: "D")],
        ]]) else { Issue.record("the first page is not read as a page"); return }
        #expect(held.listSeq == 4)
        #expect(held.listEpoch == "run-a")
        guard case .follow(let reply) = try message(["jsonrpc": "2.0", "id": 2, "result": [
            "follow": true, "listSeq": 9, "listEpoch": "run-a", "more": false,
            "sessions": [summary("a", indicator: "input", title: "A2"), summary("e", indicator: "working", title: "E")],
            "gone": [["sessionId": "b"], ["sessionId": "c", "peer": "box"]],
        ]]) else { Issue.record("a follow is not read as a follow"); return }
        #expect(reply.listSeq == 9)
        #expect(!reply.more)
        held.lay(reply)
        #expect(held.states["a"] == .needsInput)
        #expect(held.titles["a"] == "A2")
        #expect(held.states["e"] == .working, "a new row comes")
        #expect(held.states["b"] == nil, "a gone row goes")
        #expect(held.titles["b"] == nil)
        #expect(held.peers["c"]?["box"] == nil, "a gone peer row goes")
        #expect(held.states["d"] == .needsInput, "a row the follow does not name stands")
        #expect(held.titles["d"] == "D")

        var follow = AgentListFollow()
        follow.follows = true
        follow.listed(seq: 4, epoch: "run-a")
        follow.followed(reply)
        #expect(follow.cursor?.seq == 9)
        #expect(follow.cursor?.epoch == "run-a")
    }

    @Test func aResetIsAFirstListOfTheNewRun() throws {
        guard case .page(let page, let continued) = try message(["jsonrpc": "2.0", "id": 2, "result": [
            "reset": true, "listSeq": 3, "listEpoch": "run-b", "sessions": [summary("z", indicator: "working", title: "Z")],
        ]]) else { Issue.record("a reset is not read as a whole page"); return }
        #expect(!continued)
        var follow = AgentListFollow()
        follow.follows = true
        follow.listed(seq: 50, epoch: "run-a")
        follow.listed(seq: page.listSeq, epoch: page.listEpoch)
        #expect(follow.cursor?.epoch == "run-b")
        #expect(follow.cursor?.seq == 3, "the old run's position is not kept")
        #expect(page.states["z"] == .working)
    }

    @Test func aPushOlderThanTheRowHeldChangesNothing() throws {
        var follow = AgentListFollow()
        follow.follows = true
        follow.listed(seq: 10, epoch: "run-a")
        let a = AgentListRow(session: "a", peer: nil)
        let admitted1 = follow.admits(a, listSeq: 9)
        #expect(!admitted1, "older than the reply that listed it")
        let admitted2 = follow.admits(a, listSeq: 10)
        #expect(admitted2)
        let admitted3 = follow.admits(a, listSeq: 12)
        #expect(admitted3)
        #expect(follow.cursor?.seq == 12)
        let admitted4 = follow.admits(a, listSeq: 11)
        #expect(!admitted4, "older than the push it holds")
        let admitted5 = follow.admits(AgentListRow(session: "b", peer: nil), listSeq: 11)
        #expect(admitted5, "another row's push is its own")
        #expect(follow.cursor?.seq == 12, "the cursor never goes back")
        // Lines dropped after a batch that moved the cursor: a follow starts before the batch.
        follow.rewind(to: ("run-a", 10))
        #expect((follow.watchParams["afterSeq"] as? UInt64) == 10)

        guard case .change(_, _, _, _, _, _, _, _, _, _, _, _, _, let listSeq) = try message([
            "jsonrpc": "2.0", "method": "_acpmux/session_changed",
            "params": ["sessionId": "a", "kind": "status", "listSeq": 13, "session": summary("a", indicator: "working", title: "A")],
        ]) else { Issue.record("a push is not read"); return }
        #expect(listSeq == 13)
    }

    @Test func anOlderDaemonIsReadAsBefore() throws {
        var follow = AgentListFollow()
        guard case .initialized(let follows) = try message(["jsonrpc": "2.0", "id": 1, "result": ["_meta": ["acpmux": [:]]]]) else {
            Issue.record("initialize is not read"); return
        }
        follow.follows = follows
        guard case .page(let page, _) = try message(["jsonrpc": "2.0", "id": 2, "result": [
            "sessions": [summary("a", indicator: "working", title: "A")],
        ]]) else { Issue.record("a list without a position is not a page"); return }
        follow.listed(seq: page.listSeq, epoch: page.listEpoch)
        #expect(follow.cursor == nil)
        #expect(!follow.canFollow)
        let admitted6 = follow.admits(AgentListRow(session: "a", peer: nil), listSeq: nil)
        #expect(admitted6, "a push without a position is always applied")
        let sent = try requests(AgentTurnStateFeed.watchRequest(follow.watchParams))
        #expect(sent.compactMap { $0["method"] as? String } == ["initialize", "_acpmux/watch", "_acpmux/sessions"])
        #expect((sent[1]["params"] as? [String: Any])?.keys.sorted() == ["enabled"])
        // Even with a position held, a daemon that never named the capability is asked the whole list.
        follow.listed(seq: 5, epoch: "run-a")
        #expect(follow.watchParams.keys.sorted() == ["enabled"])
        // Only a watch's lag is the list's; another lag is left as before.
        let lagged = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "_acpmux/lagged", "params": ["sessionIds": ["a"]]])
        #expect(AgentTurnStateFeed.Message(line: lagged) == nil)
        guard case .lagged = try message(["jsonrpc": "2.0", "method": "_acpmux/lagged", "params": ["watch": true]]) else {
            Issue.record("a watch's lag is not read"); return
        }
    }
}
