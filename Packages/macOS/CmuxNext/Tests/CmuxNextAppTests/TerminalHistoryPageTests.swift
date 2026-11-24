import CmuxNextDaemon
import CmuxNextAgentPane
import Testing

@MainActor
@Suite struct TerminalHistoryPageTests {
    @Test func hookSessionSelectsOnlyItsOwnHarnessHistory() {
        let hook = "cmux-hook-shell"
        func status(_ agent: String, _ sessionID: String?) -> AgentStatus {
            AgentStatus(surface: 1, state: .idle, source: "hook", session: hook, agent: agent, agentSessionID: sessionID)
        }
        #expect(TerminalHistorySource.chatKey(status("claude_code", "same-id")) == "claude-code:same-id")
        #expect(TerminalHistorySource.chatKey(status("codex", "same-id")) == "codex:same-id")
        #expect(TerminalHistorySource.chatKey(status("claude", nil)) == nil)
        #expect(TerminalHistorySource.chatKey(status("muse", "same-id")) == nil)
        #expect(TerminalHistorySource.chatKey(nil) == nil)
    }
}
