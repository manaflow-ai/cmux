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
        let executable = startupExecutableInvocation(
            executablePath: executablePath,
            runtimeSearchPath: runtimeSearchPath
        )
        let interactiveCommand: String? = switch self {
        case .current:
            nil
        case .claude, .codex, .grok, .opencode, .omp, .pi, .amp, .cursor,
             .gemini, .antigravity, .codebuddy, .factory:
            "exec \(executable)"
        case .kiro:
            // The cmux profile is optional and installed separately. Preserve
            // interactive transfer for a plain Kiro installation while using
            // hooks whenever that profile is available at launch time.
            "if [[ -f \"${KIRO_HOME:-${HOME:-}/.kiro}/agents/cmux.json\" ]]; then exec \(executable) chat --agent cmux; else exec \(executable) chat; fi"
        case .hermesAgent:
            "exec \(executable) chat --tui"
        case .copilot:
            "exec \(executable) --interactive"
        }
        guard let interactiveCommand else { return nil }
        return AgentConversationForkFirstMessageAdapter.startupCommand(
            interactiveCommand: interactiveCommand,
            firstMessage: handoffMessage
        )
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

    /// A successful `--version` is only accepted when either its output or the
    /// resolved install path identifies the expected harness. This rejects an
    /// unrelated executable renamed to a generic alias such as `cbc`.
    func versionProbeMatches(output: String, resolvedExecutablePath: String) -> Bool {
        guard self != .current else { return false }
        let normalizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOutput.isEmpty,
              normalizedOutput.range(
                  of: #"[0-9]+(?:\.[0-9]+){1,3}"#,
                  options: .regularExpression
              ) != nil else {
            return false
        }
        let identityEvidence = (normalizedOutput + "\n" + resolvedExecutablePath).lowercased()
        return versionIdentityMarkers.contains { identityEvidence.contains($0) }
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
        case .hermesAgent:
            ["hermes"]
        case .copilot:
            ["copilot"]
        case .codebuddy:
            ["codebuddy", "code-buddy"]
        case .factory:
            ["factory", "/droid"]
        }
    }
}

/// Starts an interactive harness in a child PTY and submits the transfer as its
/// first terminal message. The enclosing private one-shot launcher self-deletes
/// before this adapter runs, so neither the harness nor the long-lived PTY proxy
/// exposes the transcript in process arguments.
struct AgentConversationForkFirstMessageAdapter {
    private static let heredocDelimiter = "CMUX_CONVERSATION_FIRST_MESSAGE"

    static func startupCommand(
        interactiveCommand: String,
        firstMessage: String
    ) -> String {
        let encodedCommand = hexEncoded(interactiveCommand)
        let encodedMessage = hexEncoded(firstMessage)
        return """
        [[ -x /usr/bin/expect ]] || exit 127
        /usr/bin/expect -f - <<'\(heredocDelimiter)'
        set timeout -1
        set cmux_command [encoding convertfrom utf-8 [binary format H* {\(encodedCommand)}]]
        set cmux_message [encoding convertfrom utf-8 [binary format H* {\(encodedMessage)}]]
        spawn -noecho /bin/zsh -lc $cmux_command
        after 150
        send -- "\\033\\[200~"
        send -- $cmux_message
        send -- "\\033\\[201~\\r"
        if {[catch {stty -g}]} {
          expect eof
        } else {
          interact
        }
        set cmux_wait [wait]
        exit [lindex $cmux_wait 3]
        \(heredocDelimiter)
        """
    }

    private static func hexEncoded(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
