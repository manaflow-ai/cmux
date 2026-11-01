import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Open Terminal as Chat (`palette.openTerminalChatView`, `cmux agent open-terminal-as-chat`):
/// the focused terminal's Claude Code or Codex session opens as an agent chat tab that resumes
/// the same session over ACP (acpmux adopt). It is a working action, not a greyed-out row.
@MainActor @Suite(.serialized)
struct TerminalChatTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    @Test func openTerminalAsChatIsAWorkingAction() {
        let services = Self.services()
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: "palette.openTerminalChatView") == nil)
    }

    static func status(agent: String?, session: String?) -> AgentStatus {
        AgentStatus(surface: 1, state: .working, source: "hook", session: session, agent: agent)
    }

    @Test(arguments: [("claude", "claude"), ("claude-code", "claude"), ("Claude_Code", "claude"), ("codex", "codex")])
    func aClaudeOrCodexSessionOpensAsAChatResumingIt(agent: String, harness: String) {
        let route = TerminalChatRoute.route(Self.status(agent: agent, session: "s-123"), openTab: { _ in nil })
        #expect(route == .open(AgentPaneAdopt(harness: harness, agentSessionId: "s-123")))
    }

    /// A hook-reported terminal (every Claude Code and Codex with cmux hooks) names its session in
    /// `agent_session_id`; `session` is only a label.
    @Test func aHookReportedSessionOpensAsAChatResumingIt() {
        let status = AgentStatus(surface: 1, state: .idle, source: "hook", session: "Claude Code", agent: "codex",
                                 agentSessionID: "01a14344-2fe7-7e33-8f68-5e342115469c")
        let route = TerminalChatRoute.route(status, openTab: { _ in nil })
        #expect(route == .open(AgentPaneAdopt(harness: "codex", agentSessionId: "01a14344-2fe7-7e33-8f68-5e342115469c")))
    }

    @Test func aSessionATabAlreadyResumesIsShownInsteadOfADuplicate() {
        var asked: AgentPaneAdopt?
        let route = TerminalChatRoute.route(Self.status(agent: "codex", session: "abc")) { adopt in
            asked = adopt
            return "tab-7"
        }
        #expect(route == .reveal(tab: "tab-7"))
        #expect(asked == AgentPaneAdopt(harness: "codex", agentSessionId: "abc"))
    }

    @Test func aTerminalWithoutAnAgentSessionIsRefused() {
        #expect(TerminalChatRoute.route(nil, openTab: { _ in nil }) == .noSession)
        #expect(TerminalChatRoute.route(Self.status(agent: "claude", session: nil), openTab: { _ in nil }) == .noSession)
        #expect(TerminalChatRoute.route(Self.status(agent: "claude", session: "  "), openTab: { _ in nil }) == .noSession)
    }

    @Test func anAgentACPCannotResumeIsRefused() {
        #expect(TerminalChatRoute.route(Self.status(agent: "opencode", session: "x"), openTab: { _ in nil }) == .unsupportedHarness)
        #expect(TerminalChatRoute.route(Self.status(agent: nil, session: "x"), openTab: { _ in nil }) == .unsupportedHarness)
    }
}
