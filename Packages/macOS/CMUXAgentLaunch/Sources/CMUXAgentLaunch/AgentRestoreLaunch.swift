import Foundation

/// Describes one cmux-owned agent session restore launch.
///
/// The value validates restore ownership once, then provides the provider-specific
/// wrapper route and a shell-portable authorization transport for app-generated
/// startup input. Invalid providers and unsafe session identifiers cannot create a
/// restore launch.
///
/// ```swift
/// let launch = AgentRestoreLaunch(kind: "codex", sessionID: restoredSessionID)
/// let startupInput = launch?.authorizing(leadingShell: "", routedCommand: resumeCommand)
/// ```
public struct AgentRestoreLaunch: Sendable {
    /// The readable restore executable typed into cmux-owned terminals.
    ///
    /// ``TerminalSurface`` prepends the owning app's bundled `Resources/bin`
    /// directory to the terminal environment before the login shell starts, so
    /// this resolves to the same build while keeping restored scrollback useful.
    public static let cliStartupExecutableToken = "cmux"

    private enum Provider: String, Sendable {
        case claude
        case codex
        case hermesAgent = "hermes-agent"

        var executableName: String {
            switch self {
            case .claude: "claude"
            case .codex: "codex"
            case .hermesAgent: "hermes"
            }
        }

        var wrapperShimEnvironmentKey: String {
            switch self {
            case .claude: "CMUX_CLAUDE_WRAPPER_SHIM"
            case .codex: "CMUX_CODEX_WRAPPER_SHIM"
            case .hermesAgent: "CMUX_HERMES_AGENT_WRAPPER_SHIM"
            }
        }
    }

    private let provider: Provider
    private let sessionID: String

    /// Creates an authorized restore launch for a supported provider and session.
    ///
    /// - Parameters:
    ///   - kind: The persisted agent kind.
    ///   - sessionID: The exact session identifier that the wrapper must resume.
    public init?(kind: String?, sessionID: String?) {
        guard let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let provider = Provider(rawValue: normalizedKind),
              let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.validSessionID(sessionID, for: provider) else {
            return nil
        }
        self.provider = provider
        self.sessionID = sessionID
    }

    /// The basename expected for a captured executable owned by this provider.
    public var executableName: String {
        provider.executableName
    }

    /// The managed per-surface wrapper token used to restore hook injection.
    public var wrapperShellExecutableToken: String {
        switch provider {
        case .claude: AgentResumeArgv.claudeWrapperShellExecutableToken
        case .codex: AgentResumeArgv.codexWrapperShellExecutableToken
        case .hermesAgent: AgentResumeArgv.hermesWrapperShellExecutableToken
        }
    }

    /// The environment key containing this surface's managed wrapper shim.
    public var wrapperShimEnvironmentKey: String {
        provider.wrapperShimEnvironmentKey
    }

    /// The environment key through which the wrapper preserves a captured executable.
    public var customExecutablePathEnvironmentKey: String {
        switch provider {
        case .claude: "CMUX_CUSTOM_CLAUDE_PATH"
        case .codex: "CMUX_CUSTOM_CODEX_PATH"
        case .hermesAgent: "CMUX_CUSTOM_HERMES_AGENT_PATH"
        }
    }

    /// The provider- and session-bound authorization value passed to the wrapper.
    public var authorizationEnvironmentValue: String {
        "\(provider.rawValue):\(sessionID)"
    }

    /// Wraps a provider-specific wrapper command so every supported login shell can dispatch it.
    ///
    /// - Parameter posixCommand: The command containing ``wrapperShellExecutableToken``.
    /// - Returns: A `/bin/sh -c` command that can be typed into POSIX and non-POSIX shells.
    public func portableWrapperShellCommand(posixCommand: String) -> String {
        switch provider {
        case .claude: AgentResumeArgv.portableClaudeResumeShellCommand(posixCommand: posixCommand)
        case .codex: AgentResumeArgv.portableCodexResumeShellCommand(posixCommand: posixCommand)
        case .hermesAgent: AgentResumeArgv.portableHermesResumeShellCommand(posixCommand: posixCommand)
        }
    }

    /// Adds the one-shot restore authorization before an already routed command.
    ///
    /// `/usr/bin/env` carries the assignment because startup input is parsed by the
    /// user's login shell, and csh/tcsh do not accept POSIX `NAME=value command`
    /// syntax. `leadingShell` keeps app-owned working-directory guards outside the
    /// portable wrapper command.
    ///
    /// - Parameters:
    ///   - leadingShell: Shell syntax that must remain before the command executable.
    ///   - routedCommand: The command beginning at its executable after wrapper routing.
    /// - Returns: Startup input carrying provider- and session-bound authorization.
    public func authorizing(leadingShell: String, routedCommand: String) -> String {
        let assignment = "CMUX_AGENT_RESTORE_LAUNCH=\(authorizationEnvironmentValue)"
        return leadingShell + "/usr/bin/env '\(assignment)' " + routedCommand
    }

    private static func validSessionID(_ sessionID: String, for provider: Provider) -> Bool {
        switch provider {
        case .claude, .codex:
            UUID(uuidString: sessionID) != nil
        case .hermesAgent:
            AgentRestoreCLIArgument(rawValue: sessionID) != nil
        }
    }
}
