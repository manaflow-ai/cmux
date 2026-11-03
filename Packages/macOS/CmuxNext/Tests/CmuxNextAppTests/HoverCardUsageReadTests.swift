import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// The sidebar hover card's usage row (cmux#28773) reads the chat's `usageStats` from the app's
/// turn-state watch. A plain `_acpmux/watch` list carries acpmux's last usage pass, or none when
/// nothing asked since acpmux started, so the row stayed empty or stale. The watch now asks once
/// per connection with `usage: true` (`_acpmux/sessions`, id 3) and lays those numbers over the
/// chats it lists; each turn end then brings its own over `_acpmux/session_changed`.
@MainActor
struct HoverCardUsageReadTests {
    static let host = "install:hover-usage"

    static func line(_ object: [String: Any]) -> AgentTurnStateFeed.Message? {
        AgentTurnStateFeed.Message(line: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    static func page(_ sessions: [[String: Any]]) -> AgentTurnStateFeed.Message? {
        line(["jsonrpc": "2.0", "id": 2, "result": ["sessions": sessions]])
    }

    static func usage(_ sessions: [[String: Any]], next: String? = nil) -> AgentTurnStateFeed.Message? {
        var result: [String: Any] = ["sessions": sessions]
        if let next { result["nextCursor"] = next }
        return line(["jsonrpc": "2.0", "id": 3, "result": result])
    }

    static let stats: [String: Any] = ["contextTokens": 312_000, "contextWindow": 1_000_000, "costUsd24h": 1_420.5,
                                       "updatedAt": 1_761_800_000_000]

    static func chat(_ session: String) -> AgentSessionRef { AgentSessionRef(host: host, session: session, harness: "claude") }

    /// Each JSON request the watch sends when it connects.
    static func requests() -> [[String: Any]] {
        String(decoding: AgentTurnStateFeed.watchRequest, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    @Test func theWatchAsksForEveryChatsUsageOnceWhenItConnects() throws {
        let reads = Self.requests().filter { $0["method"] as? String == "_acpmux/sessions" }
        #expect(reads.count == 1, "one usage read per connection, never one per change")
        let params = try #require(reads.first?["params"] as? [String: Any])
        #expect(params["usage"] as? Bool == true)
        #expect((reads.first?["id"] as? NSNumber)?.intValue == 3)
        // The watch itself stays a plain list: its pushes never wait on a usage pass.
        let watch = try #require(Self.requests().first { $0["method"] as? String == "_acpmux/watch" })
        #expect((watch["params"] as? [String: Any])?["usage"] == nil)
    }

    @Test func theUsageReadFillsTheCardsNumbersAndKeepsTheRest() throws {
        let turns = AgentTurnStateStore()
        turns.localHost = Self.host
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/hover-usage.sock", turns: turns, lanes: AgentLaneStore())
        // The watch's list: acpmux has read no usage since it started.
        feed.handle(try #require(Self.page([["sessionId": "s1", "status": "idle", "model": "claude-opus-5-5"]])))
        #expect(turns.detail(for: Self.chat("s1"))?.costUsd24h == nil)

        feed.handle(try #require(Self.usage([["sessionId": "s1", "model": "claude-opus-5-5", "usageStats": Self.stats],
                                             ["sessionId": "not-listed", "usageStats": Self.stats]])))
        let detail = try #require(turns.detail(for: Self.chat("s1")))
        #expect(detail.contextTokens == 312_000)
        #expect(detail.contextWindow == 1_000_000)
        #expect(detail.costUsd24h == 1_420.5)
        #expect(detail.model == "claude-opus-5-5")
        // A chat the watch never listed gets nothing from the read.
        #expect(turns.detail(for: Self.chat("not-listed")) == nil)
    }

    @Test func aUsageReadThatAnswersBeforeTheWatchsListStillCounts() throws {
        let turns = AgentTurnStateStore()
        turns.localHost = Self.host
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/hover-usage.sock", turns: turns, lanes: AgentLaneStore())
        feed.handle(try #require(Self.usage([["sessionId": "s1", "usageStats": Self.stats]])))
        feed.handle(try #require(Self.page([["sessionId": "s1", "status": "idle", "model": "m"]])))
        #expect(turns.detail(for: Self.chat("s1"))?.costUsd24h == 1_420.5)
        #expect(turns.detail(for: Self.chat("s1"))?.model == "m")
    }

    @Test func aUsagePageNamesItsNextCursor() throws {
        guard case .usage(let numbers, let next) = try #require(Self.usage([["sessionId": "s1", "usageStats": Self.stats],
                                                                             ["sessionId": "s2", "status": "idle"]],
                                                                            next: "c2")) else {
            Issue.record("an id 3 reply is a usage page")
            return
        }
        #expect(next == "c2")
        #expect(Set(numbers.keys) == ["s1"], "a chat with no usage read is left out")
        let following = String(decoding: AgentTurnStateFeed.usageRequest(cursor: "c2"), as: UTF8.self)
        let request = try #require(try JSONSerialization.jsonObject(with: Data(following.utf8)) as? [String: Any])
        #expect((request["params"] as? [String: Any])?["cursor"] as? String == "c2")
        #expect((request["params"] as? [String: Any])?["usage"] as? Bool == true)
    }
}
