import CmuxMobileAgentChat
import CmuxMobileFeed
import Foundation
import Testing
@testable import CmuxMobileLive

/// A chat's Feed card names the agent that answered ("Claude", "Codex"), never the id the Chief or
/// acpmux gave its session (`optchat-sub-<home>-a12`, `claude-2`): before, the Chief's agents showed
/// as "optchat-sub-…" in the Feed and the chat lists.
@MainActor
@Suite struct FeedAgentNameTests {
    func session(_ name: String, harness: String) throws -> AcpmuxSession {
        let line = #"{"sessionId":"s1","name":"\#(name)","harness":"\#(harness)","cwd":"/tmp/w","status":"ready","pendingPermissions":0,"lastSeq":3,"preview":"Done.","lastTurn":{"status":"completed","turnId":"t1"}}"#
        return try #require(AcpmuxSession(try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))))
    }

    @Test func aChatsFeedCardNamesItsAgent() throws {
        let feed = LiveFeed(store: FeedStore(items: []), hub: AcpmuxHub(), place: { _ in nil })
        for (name, harness, agent) in [
            ("optchat-sub-b902d10e-a12", "claude", "Claude"), ("optchat-b902d10e-816", "codex", "Codex"),
            ("claude-2", "claude", "Claude"), ("fix-tests", "codex", "Codex"),
        ] {
            let item = feed.turnItem(try session(name, harness: harness), fallbackKey: "t1", at: Date())
            #expect(item.agentName == agent, "\(name)")
        }
    }

    @Test func aChatListNeverShowsTheChiefsSessionIDs() throws {
        #expect(try session("optchat-sub-b902d10e-a12", harness: "claude").shownName == nil)
        #expect(try session("optchat-sub-b902d10e-a12", harness: "claude").displayName == "Claude")
        #expect(try session("optchat-compact-x", harness: "codex").displayName == "Codex")
        #expect(try session("", harness: "codex").displayName == "Codex")
        #expect(try session("Release notes", harness: "claude").displayName == "Release notes")
    }
}
