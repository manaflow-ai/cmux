import Foundation

/// Describes one cmux-owned Claude or Codex session restore launch.
///
/// The value validates restore ownership once, then provides the provider-specific
/// wrapper route and a shell-portable authorization transport for app-generated
/// startup input. Invalid providers and non-UUID session identifiers cannot create
/// a restore launch.
///
/// ```swift
/// let launch = AgentRestoreLaunch(kind: "codex", sessionID: restoredSessionID)
/// let startupInput = launch?.authorizing(leadingShell: "", routedCommand: resumeCommand)
/// ```
public struct AgentRestoreLaunch: Sendable {
    /// Shell token for the CLI bundled with the app that owns the surface.
    ///
    /// Resolving an absolute path before composing startup input avoids a second
    /// PATH lookup in the restored interactive shell. The app-bundled CLI is
    /// preferred; an already-resolved executable from the app's PATH is accepted
    /// only as a compatibility fallback. The quoting form is accepted by the
    /// supported POSIX, fish, and csh-family interactive shells.
    ///
    /// - Parameters:
    ///   - bundledCLIPath: The app-relative CLI candidate.
    ///   - executableSearchPath: Absolute directories that may contain a fallback CLI.
    ///   - isExecutableFile: The executable-path lookup used to validate the candidate.
    /// - Returns: A quoted absolute token, or `nil` when no trustworthy CLI exists.
    public static func bundledCLIStartupExecutableToken(
        bundledCLIPath: String? = Bundle.main.resourceURL?
            .appendingPathComponent("bin/cmux", isDirectory: false)
            .path,
        executableSearchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutableFile: @Sendable (String) -> Bool = {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: $0)
        }
    ) -> String? {
        var candidates: [String] = []
        if let bundledCLIPath {
            candidates.append(bundledCLIPath)
        }
        if let executableSearchPath {
            for directory in executableSearchPath.split(
                separator: ":",
                omittingEmptySubsequences: false
            ) {
                let root = String(directory)
                guard root.hasPrefix("/") else { continue }
                candidates.append(
                    URL(fileURLWithPath: root, isDirectory: true)
                        .appendingPathComponent("cmux", isDirectory: false)
                        .path
                )
            }
        }
        guard let path = candidates.first(where: {
            $0.hasPrefix("/")
                && !$0.isEmpty
                && $0.rangeOfCharacter(from: .newlines) == nil
                && isExecutableFile($0)
        }) else {
            return nil
        }
        let unescapedScalars = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "/._-")
        )
        return path.unicodeScalars.map { scalar in
            unescapedScalars.contains(scalar) ? String(scalar) : "\\\(scalar)"
        }.joined()
    }

    /// Returns whether a persisted identifier can be typed as one restore CLI argument.
    ///
    /// This deliberately excludes leading hyphens and every character that
    /// requires shell quoting, so startup input cannot be reinterpreted as an
    /// option or multiple shell tokens.
    ///
    /// - Parameter value: The already-trimmed binding kind or checkpoint identifier.
    /// - Returns: `true` when the value is safe to emit without quoting.
    public static func isSafeRestoreCLIArgument(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9._:+][A-Za-z0-9._:+-]*$",
            options: .regularExpression
        ) != nil
    }

    private enum Provider: String, Sendable {
        case claude
        case codex
    }

    private let provider: Provider
    private let sessionID: String

    /// Creates an authorized restore launch for a supported provider and UUID session.
    ///
    /// - Parameters:
    ///   - kind: The persisted agent kind. Only `claude` and `codex` are supported.
    ///   - sessionID: The exact session identifier that the wrapper must resume.
    public init?(kind: String?, sessionID: String?) {
        guard let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let provider = Provider(rawValue: normalizedKind),
              let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: sessionID) != nil else {
            return nil
        }
        self.provider = provider
        self.sessionID = sessionID
    }

    /// The basename expected for a captured executable owned by this provider.
    public var executableName: String {
        provider.rawValue
    }

    /// The managed per-surface wrapper token used to restore hook injection.
    public var wrapperShellExecutableToken: String {
        switch provider {
        case .claude: AgentResumeArgv.claudeWrapperShellExecutableToken
        case .codex: AgentResumeArgv.codexWrapperShellExecutableToken
        }
    }

    /// The environment key through which the wrapper preserves a captured executable.
    public var customExecutablePathEnvironmentKey: String {
        switch provider {
        case .claude: "CMUX_CUSTOM_CLAUDE_PATH"
        case .codex: "CMUX_CUSTOM_CODEX_PATH"
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
}
