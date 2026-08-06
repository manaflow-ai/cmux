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
    case campfire
    case pi
    case amp
    case cursor
    case gemini
    case kiro
    case antigravity
    case rovodev
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

    func usesNativeFork(for sourceKind: RestorableAgentKind) -> Bool {
        self == .current || rawValue == sourceKind.rawValue
    }

    func supportsFork(from sourceKind: RestorableAgentKind, isRemoteSource: Bool) -> Bool {
        !isRemoteSource || usesNativeFork(for: sourceKind)
    }

    func startupCommand(
        handoffMessage: String,
        executablePath: String? = nil,
        runtimeSearchPath: String? = nil,
        executableBinding: AgentConversationForkExecutableBinding? = nil,
        executableLookupPath: String? = nil,
        recipientExecutablePath: String? = nil
    ) -> String? {
        let executable = startupExecutableInvocation(
            executablePath: executablePath,
            runtimeSearchPath: runtimeSearchPath
        )
        let execPrefix = executableBinding == nil ? "exec " : ""
        let interactiveCommand: String? = switch self {
        case .current:
            nil
        case .claude, .codex, .grok, .opencode, .omp, .campfire, .pi, .amp,
             .cursor, .gemini, .antigravity, .copilot, .codebuddy, .factory,
             .qoder, .kimi:
            "\(execPrefix)\(executable)"
        case .kiro:
            // The cmux profile is optional and installed separately. Preserve
            // interactive transfer for a plain Kiro installation while using
            // hooks whenever that profile is available at launch time.
            "if [[ -f \"${KIRO_HOME:-${HOME:-}/.kiro}/agents/cmux.json\" ]]; then \(execPrefix)\(executable) chat --agent cmux; else \(execPrefix)\(executable) chat; fi"
        case .rovodev:
            if Self.executableBasename(executableLookupPath ?? executablePath) == "acli" {
                "\(execPrefix)\(executable) rovodev run"
            } else {
                "\(execPrefix)\(executable)"
            }
        case .hermesAgent:
            "\(execPrefix)\(executable) chat --tui"
        }
        guard let interactiveCommand else { return nil }
        let launchCommand = executableBinding?.shellCommand(
            running: interactiveCommand
        ) ?? interactiveCommand
        return AgentConversationForkFirstMessageAdapter.startupCommand(
            interactiveCommand: launchCommand,
            firstMessage: handoffMessage,
            readinessPattern: firstMessageReadinessPattern,
            recipientExecutablePath: recipientExecutablePath
                ?? executableLookupPath
                ?? executablePath
                ?? preferredExecutableName
        )
    }

    /// Terminal output that is unique to the harness's editable prompt. Broad
    /// selection glyphs are intentionally avoided because onboarding and trust
    /// screens often use the same arrows as the main editor.
    private var firstMessageReadinessPattern: String {
        switch self {
        case .current:
            ""
        case .claude:
            "(accept edits|plan|auto|manual|bypass permissions).*(mode )?on"
        case .codex:
            "Context [0-9]+% left|[0-9]+% context left"
        case .grok:
            "Grok Build"
        case .opencode:
            "Ask anything\\.\\.\\."
        case .omp:
            "Recent sessions"
        case .campfire, .pi:
            "\\(sub\\).*%"
        case .amp:
            "ctrl\\+o.*for commands"
        case .cursor:
            "Plan, search, build anything"
        case .gemini, .antigravity:
            "Type your message or @path/to/file"
        case .kiro:
            "Use Ctrl.*multi-line prompts"
        case .rovodev:
            "Rovo Dev"
        case .hermesAgent:
            "Available.*Tools"
        case .copilot:
            "Shift.*Tab"
        case .codebuddy:
            "(auto|manual).*mode on|Context [0-9]+% left"
        case .factory:
            "Shift.*Tab|Context [0-9]+% left"
        case .qoder:
            "Qoder|accept_edits|bypass_permissions|dont_ask"
        case .kimi:
            "What would you like to do\\?"
        }
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
        case .current, .grok, .omp, .campfire, .pi, .amp, .cursor, .gemini,
             .kiro, .antigravity, .rovodev, .hermesAgent, .copilot, .codebuddy,
             .factory, .qoder, .kimi:
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
        case .campfire:
            ["campfire"]
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
        case .rovodev:
            ["acli", "rovodev", "rovo", "rovo-dev"]
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

    /// A successful `--version` is accepted only when its output is compatible
    /// with the expected harness. The exact source path is disclosed separately
    /// in the user confirmation that gates transcript submission.
    func versionProbeMatches(
        output: String,
        resolvedExecutablePath _: String
    ) -> Bool {
        guard self != .current else { return false }
        let normalizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOutput.isEmpty,
              normalizedOutput.range(
                  of: #"[0-9]+(?:\.[0-9]+){1,3}"#,
                  options: .regularExpression
              ) != nil else {
            return false
        }
        let compatibilityEvidence = normalizedOutput.lowercased()
        return versionIdentityMarkers.contains { compatibilityEvidence.contains($0) }
    }

    /// Help output is the fallback compatibility probe for tools whose version
    /// output is only a number. This runs after an explicit fork selection.
    func helpProbeMatches(_ output: String) -> Bool {
        guard self != .current,
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return output.range(
            of: helpIdentityPattern,
            options: [.caseInsensitive, .regularExpression]
        ) != nil
    }

    func versionProbeArguments(resolvedExecutablePath _: String) -> [String] {
        ["--version"]
    }

    func helpProbeArguments(resolvedExecutablePath: String) -> [String] {
        if self == .rovodev,
           Self.executableBasename(resolvedExecutablePath) == "acli" {
            return ["rovodev", "--help"]
        }
        return ["--help"]
    }

    private var versionIdentityMarkers: [String] {
        switch self {
        case .current:
            []
        case .claude:
            ["claude"]
        case .codex:
            ["codex"]
        case .grok:
            ["grok"]
        case .opencode:
            ["opencode", "open-code"]
        case .omp:
            ["omp", "oh-my-pi"]
        case .campfire:
            ["campfire"]
        case .pi:
            ["pi-coding-agent"]
        case .amp:
            ["/.amp/", "ampcode", "@ampcode"]
        case .cursor:
            ["cursor"]
        case .gemini:
            ["gemini"]
        case .kiro:
            ["kiro"]
        case .antigravity:
            ["antigravity", "/agy"]
        case .rovodev:
            ["rovo dev", "rovodev"]
        case .hermesAgent:
            ["hermes"]
        case .copilot:
            ["copilot"]
        case .codebuddy:
            ["codebuddy", "code-buddy"]
        case .factory:
            ["factory", "/droid"]
        case .qoder:
            ["qoder"]
        case .kimi:
            ["kimi"]
        }
    }

    private var helpIdentityPattern: String {
        switch self {
        case .current:
            #"$^"#
        case .claude:
            #"Claude Code"#
        case .codex:
            #"Codex"#
        case .grok:
            #"Grok"#
        case .opencode:
            #"opencode"#
        case .omp:
            #"(^|[^A-Za-z])OMP([^A-Za-z-]|$)|oh-my-pi"#
        case .campfire:
            #"usage:\s*campfire"#
        case .pi:
            #"pi\s+-\s+AI coding assistant|pi-coding-agent"#
        case .amp:
            #"Amp CLI"#
        case .cursor:
            #"Cursor Agent"#
        case .gemini:
            #"Gemini CLI"#
        case .kiro:
            #"Kiro"#
        case .antigravity:
            #"Antigravity"#
        case .rovodev:
            #"Rovo Dev|rovodev"#
        case .hermesAgent:
            #"Hermes Agent"#
        case .copilot:
            #"GitHub Copilot|Copilot CLI"#
        case .codebuddy:
            #"CodeBuddy|Code Buddy"#
        case .factory:
            #"Factory|Droid"#
        case .qoder:
            #"Qoder"#
        case .kimi:
            #"Kimi"#
        }
    }

    private static func executableBasename(_ path: String?) -> String {
        guard let path else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent.lowercased()
    }
}
