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

    /// Installed targets are detected once per app launch because command-palette
    /// contributions are declarative and keep their choice lists for that launch.
    static let liveInstalledCases: [Self] = installedCases(
        providerInstalled: { provider in
            let resolver = AgentExecutableResolver(
                configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths()
            )
            return (try? resolver.resolve(provider)) != nil
        },
        executableInstalled: liveExecutableInstalled
    )

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

    func startupCommand(handoffMessage: String) -> String? {
        // These interactive CLIs require their seed through an argv or documented
        // first-message adapter; writing it to their live stdin would race TUI startup.
        let quotedMessage = TerminalStartupShellQuoting.singleQuoted(handoffMessage)
        return switch self {
        case .current:
            nil
        case .claude:
            "claude \(quotedMessage)"
        case .codex:
            "codex \(quotedMessage)"
        case .grok:
            "grok \(quotedMessage)"
        case .opencode:
            Self.openCodeStartupCommand(handoffMessage: handoffMessage)
        case .omp:
            "omp \(quotedMessage)"
        case .pi:
            "pi -- \(quotedMessage)"
        case .amp:
            // Amp documents piped stdin as the first user message in interactive mode.
            "printf '%s\\n' \(quotedMessage) | amp"
        case .cursor:
            "cursor-agent \(quotedMessage)"
        case .gemini:
            "gemini --prompt-interactive \(quotedMessage)"
        case .kiro:
            "kiro-cli chat \(quotedMessage)"
        case .antigravity:
            "agy --prompt-interactive \(quotedMessage)"
        case .hermesAgent:
            "hermes chat --tui --query \(quotedMessage)"
        case .copilot:
            "copilot --interactive \(quotedMessage)"
        case .codebuddy:
            "codebuddy \(quotedMessage)"
        case .factory:
            "droid \(quotedMessage)"
        case .qoder:
            "qodercli --prompt-interactive \(quotedMessage)"
        case .kimi:
            "kimi --prompt \(quotedMessage)"
        }
    }

    private var providerID: AgentSessionProviderID? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        case .current, .grok, .omp, .pi, .amp, .cursor, .gemini, .kiro,
             .antigravity, .hermesAgent, .copilot, .codebuddy, .factory, .qoder, .kimi:
            nil
        }
    }

    private var executableNames: [String] {
        switch self {
        case .current, .claude, .codex, .opencode:
            []
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

    private static func liveExecutableInstalled(_ names: [String]) -> Bool {
        let resolver = AgentExecutableResolver()
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let supplementalDirectories = [
            ".grok/bin",
            ".amp/bin",
            ".cursor/bin",
            ".gemini/bin",
            ".kiro/bin",
            ".antigravity/bin",
            ".factory/bin",
            ".qoder/bin",
            ".hermes/bin",
            ".kimi/bin",
        ].map { "\(home)/\($0)" }
        let directories = resolver.resolvedSearchDirectories() + supplementalDirectories
        for directory in directories {
            for name in names {
                let path = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent(name, isDirectory: false)
                    .standardizedFileURL
                    .path
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      FileManager.default.isExecutableFile(atPath: path) else {
                    continue
                }
                return true
            }
        }
        return false
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
