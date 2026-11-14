import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextWindowRules
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

    // The route itself is Rust's (cmux-window-rules `tabs::terminal_chat`, with its cases);
    // these hold the app's reading of it over the FFI.
    @Test(arguments: [("claude", "claude"), ("claude-code", "claude"), ("Claude_Code", "claude"), ("codex", "codex")])
    func aClaudeOrCodexSessionOpensAsAChatResumingIt(agent: String, harness: String) {
        #expect(WindowRules().terminalChat(agent: agent, session: "s-123") == .adopt(harness: harness, session: "s-123"))
        #expect(WindowRules().agentHarness(agent) == harness)
    }

    @Test func aTerminalWithoutAnAgentSessionIsRefused() {
        #expect(WindowRules().terminalChat(agent: "claude", session: nil) == .noSession)
        #expect(WindowRules().terminalChat(agent: "claude", session: "  ") == .noSession)
    }

    @Test func anAgentACPCannotResumeIsRefused() {
        #expect(WindowRules().terminalChat(agent: "opencode", session: "x") == .unsupportedHarness)
        #expect(WindowRules().terminalChat(agent: nil, session: "x") == .unsupportedHarness)
        #expect(WindowRules().agentHarness("opencode") == nil)
    }
}
