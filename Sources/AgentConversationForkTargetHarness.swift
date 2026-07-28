import Foundation

/// Agent harness that receives a forked conversation.
enum AgentConversationForkTargetHarness: String, CaseIterable, Identifiable, Sendable {
    case current
    case claude
    case codex
    case opencode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current:
            String(localized: "forkConversation.harness.current", defaultValue: "Current Harness")
        case .claude:
            String(localized: "forkConversation.harness.claude", defaultValue: "Claude Code")
        case .codex:
            String(localized: "forkConversation.harness.codex", defaultValue: "Codex")
        case .opencode:
            String(localized: "forkConversation.harness.opencode", defaultValue: "OpenCode")
        }
    }

    func usesNativeFork(for sourceKind: RestorableAgentKind) -> Bool {
        self == .current || rawValue == sourceKind.rawValue
    }

    func startupCommand(handoffMessage: String) -> String? {
        switch self {
        case .current:
            nil
        case .claude:
            "claude \(TerminalStartupShellQuoting.singleQuoted(handoffMessage))"
        case .codex:
            "codex \(TerminalStartupShellQuoting.singleQuoted(handoffMessage))"
        case .opencode:
            "opencode --prompt \(TerminalStartupShellQuoting.singleQuoted(handoffMessage))"
        }
    }
}
