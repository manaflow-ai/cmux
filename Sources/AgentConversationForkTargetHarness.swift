import Foundation

/// Agent harness that receives a forked conversation.
enum AgentConversationForkTargetHarness: String, CaseIterable, Hashable, Identifiable, Sendable {
    case current
    case claude
    case codex
    case grok
    case opencode
    case omp
    case pi
    case amp
    case cursor
    case gemini
    case kiro
    case antigravity
    case hermesAgent = "hermes-agent"
    case copilot
    case codebuddy
    case factory
    case qoder
    case kimi

    var id: String { rawValue }

    var title: String {
        guard self != .current else {
            return String(localized: "forkConversation.harness.current", defaultValue: "Current Harness")
        }
        return CmuxTaskManagerCodingAgentDefinition.builtIns
            .first { $0.id == rawValue }?
            .displayName
            ?? rawValue
    }

    static func installedCases(
        providerInstalled: (AgentSessionProviderID) -> Bool,
        executableInstalled: ([String]) -> Bool
    ) -> [Self] {
        allCases.filter { harness in
            guard harness != .current else { return false }
            if let provider = harness.providerID {
                return providerInstalled(provider)
            }
            return executableInstalled(harness.executableNames)
        }
    }

    func usesNativeFork(for sourceKind: RestorableAgentKind) -> Bool {
        self == .current || rawValue == sourceKind.rawValue
    }

    func supportsFork(from sourceKind: RestorableAgentKind, isRemoteSource: Bool) -> Bool {
        !isRemoteSource || usesNativeFork(for: sourceKind)
    }

    func startupCommand(
        handoffMessage: String,
        executablePath: String? = nil
    ) -> String? {
        // These interactive CLIs require their seed through an argv or documented
        // first-message adapter; writing it to their live stdin would race TUI startup.
        let quotedMessage = TerminalStartupShellQuoting.singleQuoted(handoffMessage)
        let executable = executablePath.map { path in
            path.contains("/")
                ? TerminalStartupShellQuoting.singleQuoted(path)
                : path
        } ?? preferredExecutableName
        return switch self {
        case .current:
            nil
        case .claude:
            "\(executable) \(quotedMessage)"
        case .codex:
            "\(executable) \(quotedMessage)"
        case .grok:
            "\(executable) \(quotedMessage)"
        case .opencode:
            Self.openCodeStartupCommand(
                handoffMessage: handoffMessage,
                executable: executable
            )
        case .omp:
            "\(executable) \(quotedMessage)"
        case .pi:
            "\(executable) -- \(quotedMessage)"
        case .amp:
            // Amp documents piped stdin as the first user message in interactive mode.
            "printf '%s\\n' \(quotedMessage) | \(executable)"
        case .cursor:
            "\(executable) \(quotedMessage)"
        case .gemini:
            "\(executable) --prompt-interactive \(quotedMessage)"
        case .kiro:
            "\(executable) chat \(quotedMessage)"
        case .antigravity:
            "\(executable) --prompt-interactive \(quotedMessage)"
        case .hermesAgent:
            "\(executable) chat --tui --query \(quotedMessage)"
        case .copilot:
            "\(executable) --interactive \(quotedMessage)"
        case .codebuddy:
            "\(executable) \(quotedMessage)"
        case .factory:
            "\(executable) \(quotedMessage)"
        case .qoder:
            "\(executable) --prompt-interactive \(quotedMessage)"
        case .kimi:
            "\(executable) --prompt \(quotedMessage)"
        }
    }

    var providerID: AgentSessionProviderID? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        case .current, .grok, .omp, .pi, .amp, .cursor, .gemini, .kiro,
             .antigravity, .hermesAgent, .copilot, .codebuddy, .factory, .qoder, .kimi:
            nil
        }
    }

    var executableNames: [String] {
        switch self {
        case .current:
            []
        case .claude:
            ["claude", "claude-code", "claude_code"]
        case .codex:
            ["codex"]
        case .opencode:
            ["opencode", "opencode-ai", "open-code"]
        case .grok:
            ["grok", "grok-macos-aarch64", "grok-macos-aarch"]
        case .omp:
            ["omp"]
        case .pi:
            ["pi", "pi-coding-agent"]
        case .amp:
            ["amp"]
        case .cursor:
            ["cursor-agent"]
        case .gemini:
            ["gemini"]
        case .kiro:
            ["kiro-cli"]
        case .antigravity:
            ["agy", "antigravity"]
        case .hermesAgent:
            ["hermes", "hermes-agent"]
        case .copilot:
            ["copilot"]
        case .codebuddy:
            ["codebuddy", "cbc"]
        case .factory:
            ["droid", "factory"]
        case .qoder:
            ["qodercli", "qoder"]
        case .kimi:
            ["kimi", "kimi-cli", "kimi-code"]
        }
    }

    var preferredExecutableName: String {
        executableNames.first ?? rawValue
    }

    private static func openCodeStartupCommand(
        handoffMessage: String,
        executable: String
    ) -> String {
        let quotedMessage = TerminalStartupShellQuoting.singleQuoted(handoffMessage)
        return """
        opencode_output=$(\(executable) run --format json -- \(quotedMessage)) || { printf '%s\\n' "$opencode_output"; exit 1; }
        opencode_session=$(printf '%s\\n' "$opencode_output" | sed -n 's/.*"sessionID":"\\([^"]*\\)".*/\\1/p' | head -n 1)
        [ -n "$opencode_session" ] || { printf '%s\\n' "$opencode_output"; exit 1; }
        exec \(executable) --session "$opencode_session"
        """
    }
}
