import AppKit
import CmuxNextAgentPane
import CmuxNextDaemon
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

    @Test func compactAndFullPaneActionsShareOneAccessibleControl() {
        _ = NSApplication.shared
        var opened = 0
        let source = TerminalHistorySource(key: "codex:hook-id", cwd: nil)
        let button = TerminalHistoryButton(source: source, environment: nil) { opened += 1 }
        defer { button.discard() }
        let name = button.accessibilityLabel()
        _ = button.place(in: NSRect(x: 0, y: 0, width: 640, height: 300), top: 0, trailing: 0)
        #expect(button.imagePosition == .imageLeading)
        _ = button.place(in: NSRect(x: 0, y: 0, width: 84, height: 150), top: 0, trailing: 12)
        #expect(button.imagePosition == .imageOnly)
        #expect(name != nil && button.accessibilityLabel() == name)
        #expect(button.frame.width > 0 && button.frame.maxX <= 72)
        button.performClick(nil)
        #expect(opened == 1)
    }
}
