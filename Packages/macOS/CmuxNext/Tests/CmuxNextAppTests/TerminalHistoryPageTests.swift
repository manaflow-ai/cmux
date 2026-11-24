import CmuxNextDaemon
@testable import CmuxNextApp
import Testing

@MainActor
@Suite struct TerminalHistoryPageTests {
    @Test func hookSessionSelectsOnlyItsOwnHarnessHistory() {
        let hook = "cmux-hook-shell"
        func status(_ agent: String, _ sessionID: String?) -> AgentStatus {
            AgentStatus(surface: 1, state: .idle, source: "hook", session: hook, agent: agent, agentSessionID: sessionID)
        }
        #expect(TerminalHistoryPage.chatKey(status("claude_code", "same-id")) == "claude-code:same-id")
        #expect(TerminalHistoryPage.chatKey(status("codex", "same-id")) == "codex:same-id")
        #expect(TerminalHistoryPage.chatKey(status("claude", nil)) == nil)
        #expect(TerminalHistoryPage.chatKey(status("muse", "same-id")) == nil)
        #expect(TerminalHistoryPage.chatKey(nil) == nil)
    }
}
