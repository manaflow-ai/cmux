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
        self == .current || self == Self(sourceKind: sourceKind)
    }

    func supportsFork(from sourceKind: RestorableAgentKind, isRemoteSource: Bool) -> Bool {
        !isRemoteSource || usesNativeFork(for: sourceKind)
    }

    private init?(sourceKind: RestorableAgentKind) {
        switch sourceKind {
        case .claude:
            self = .claude
        case .codex:
            self = .codex
        case .opencode:
            self = .opencode
        case .grok, .pi, .amp, .cursor, .gemini, .kiro, .antigravity,
             .rovodev, .hermesAgent, .copilot, .codebuddy, .factory, .qoder,
             .kimi, .ollama, .custom:
            return nil
        }
    }

    func startupCommand(handoffMessage: String) -> String? {
        // These interactive CLIs require their seed as argv; stdin would consume or detach their TTY.
        switch self {
        case .current:
            nil
        case .claude:
            "claude \(TerminalStartupShellQuoting.singleQuoted(handoffMessage))"
        case .codex:
            "codex \(TerminalStartupShellQuoting.singleQuoted(handoffMessage))"
        case .opencode:
            Self.openCodeStartupCommand(handoffMessage: handoffMessage)
        }
    }

    private static func openCodeStartupCommand(handoffMessage: String) -> String {
        let quotedMessage = TerminalStartupShellQuoting.singleQuoted(handoffMessage)
        return """
        opencode_output=$(opencode run --format json -- \(quotedMessage)) || { printf '%s\\n' "$opencode_output"; exit 1; }
        opencode_session=$(printf '%s\\n' "$opencode_output" | sed -n 's/.*"sessionID":"\\([^"]*\\)".*/\\1/p' | head -n 1)
        [ -n "$opencode_session" ] || { printf '%s\\n' "$opencode_output"; exit 1; }
        exec opencode --session "$opencode_session"
        """
    }
}
