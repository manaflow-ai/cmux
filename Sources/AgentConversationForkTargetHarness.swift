import CMUXAgentLaunch
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
        executablePath: String? = nil,
        runtimeSearchPath: String? = nil
    ) -> String? {
        // These interactive CLIs require their seed through an argv or documented
        // first-message adapter; writing it to their live stdin would race TUI startup.
        let quotedMessage = TerminalStartupShellQuoting.singleQuoted(handoffMessage)
        let executable = startupExecutableInvocation(
            executablePath: executablePath,
            runtimeSearchPath: runtimeSearchPath
        )
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
            "\(executable) --prompt \(quotedMessage)"
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
            // The cmux profile is optional and installed separately. Preserve
            // interactive transfer for a plain Kiro installation while using
            // hooks whenever that profile is available at launch time.
            "if [[ -f \"${KIRO_HOME:-${HOME:-}/.kiro}/agents/cmux.json\" ]]; then \(executable) chat --agent cmux \(quotedMessage); else \(executable) chat \(quotedMessage); fi"
        case .antigravity:
            "\(executable) --prompt-interactive \(quotedMessage)"
        case .hermesAgent:
            hermesStartupCommand(executable: executable, quotedMessage: quotedMessage)
        case .copilot:
            "\(executable) --interactive \(quotedMessage)"
        case .codebuddy:
            "\(executable) \(quotedMessage)"
        case .factory:
            "\(executable) \(quotedMessage)"
        }
    }

    private func hermesStartupCommand(executable: String, quotedMessage: String) -> String {
        // Hermes treats --query as one-shot even when --tui is present. Seed a
        // persisted session quietly, recover its machine-readable ID, then
        // replace the shell with the interactive TUI for that same session.
        [
            "umask 077",
            "hermes_session_file=$(/usr/bin/mktemp -t cmux-hermes-session.XXXXXX) || exit 1",
            "trap '/bin/unlink \"$hermes_session_file\" 2>/dev/null' EXIT",
            "trap 'exit 130' HUP INT TERM",
            "\(executable) chat --query \(quotedMessage) --quiet 2>\"$hermes_session_file\"",
            "hermes_status=$?",
            "/bin/cat \"$hermes_session_file\" >&2",
            "hermes_session_id=$(/usr/bin/sed -n 's/^session_id:[[:space:]]*//p' \"$hermes_session_file\" | /usr/bin/tail -n 1)",
            "/bin/unlink \"$hermes_session_file\"",
            "trap - EXIT HUP INT TERM",
            "if [[ $hermes_status -ne 0 ]]; then exit $hermes_status; fi",
            "if [[ -z \"$hermes_session_id\" ]]; then exit 1; fi",
            "exec \(executable) chat --tui --resume \"$hermes_session_id\"",
        ].joined(separator: "; ")
    }

    private func startupExecutableInvocation(
        executablePath: String?,
        runtimeSearchPath: String?
    ) -> String {
        let resolvedExecutable = executablePath ?? preferredExecutableName
        let isResolvedPath = resolvedExecutable.contains("/")
        let executableToken: String
        var environmentAssignments: [String] = []

        if let runtimeSearchPath = runtimeSearchPath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !runtimeSearchPath.isEmpty {
            environmentAssignments.append("PATH=\(runtimeSearchPath)")
        }

        switch self {
        case .claude:
            executableToken = AgentResumeArgv.claudeWrapperShellExecutableToken
            if isResolvedPath {
                environmentAssignments.append("CMUX_CUSTOM_CLAUDE_PATH=\(resolvedExecutable)")
            }
        case .codex:
            executableToken = AgentResumeArgv.codexWrapperShellExecutableToken
            if isResolvedPath {
                environmentAssignments.append("CMUX_CUSTOM_CODEX_PATH=\(resolvedExecutable)")
            }
        default:
            executableToken = isResolvedPath
                ? TerminalStartupShellQuoting.singleQuoted(resolvedExecutable)
                : resolvedExecutable
        }

        guard !environmentAssignments.isEmpty else { return executableToken }
        let assignments = environmentAssignments
            .map(TerminalStartupShellQuoting.singleQuoted)
            .joined(separator: " ")
        return "/usr/bin/env \(assignments) \(executableToken)"
    }

    var providerID: AgentSessionProviderID? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        case .current, .grok, .omp, .pi, .amp, .cursor, .gemini, .kiro,
             .antigravity, .hermesAgent, .copilot, .codebuddy, .factory:
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
        }
    }

    var preferredExecutableName: String {
        executableNames.first ?? rawValue
    }
}
