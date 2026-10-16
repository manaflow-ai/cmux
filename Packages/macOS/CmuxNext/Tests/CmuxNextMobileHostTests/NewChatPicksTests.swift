import CmuxNextAgentPane
@testable import CmuxNextMobileHost
import Testing

/// The agent and model this Mac picked last for a new chat, as the iPhone host hands them to
/// acpmux (`_acpmux/new_chat_picks_set`), so a phone's New Agent Chat starts where this Mac's does.
struct NewChatPicksTests {
    @Test func paramsCarryTheLastAgentTheGlobalPickAndTheNewestFolders() throws {
        var picks = AgentPaneLastPicks()
        for index in 0..<(AgentPaneLastPicks.maxFolders + 3) {
            picks.record(.init(harness: "codex", model: "gpt-5.5"), folder: "/work/\(index)")
        }
        picks.record(.init(harness: "claude", model: "claude-opus-5-5"), folder: "/work/last")
        let params = NewChatPicks(lastAgent: "claude", picks: picks).params
        #expect(params["lastAgent"] as? String == "claude")
        #expect(params["global"] as? [String: String] == ["harness": "claude", "model": "claude-opus-5-5"])
        let folders = try #require(params["folders"] as? [[String: String]])
        #expect(folders.count == AgentPaneLastPicks.maxFolders)
        #expect(folders.last == ["folder": "/work/last", "harness": "claude", "model": "claude-opus-5-5"])
    }

    @Test func nothingPickedIsEmpty() {
        #expect(NewChatPicks().isEmpty)
        #expect(NewChatPicks(picks: AgentPaneLastPicks()).isEmpty)
        #expect(!NewChatPicks(lastAgent: "codex").isEmpty)
        #expect(NewChatPicks(lastAgent: "codex").params["global"] == nil)
    }
}
