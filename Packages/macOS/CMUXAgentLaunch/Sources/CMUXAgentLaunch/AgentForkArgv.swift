import Foundation

/// Builds the argument vector for an agent's fork command.
///
/// This mirrors ``AgentResumeArgv`` as pure value logic so app restore/fork UI and CLI diagnostics
/// can answer forkability from the same sanitizer-backed rules.
public struct AgentForkArgv: Sendable, Equatable {
    /// Creates a fork-argv builder. The type holds no state.
    public init() {}

    /// Resolves a fork argv from a cmux wrapper launcher.
    ///
    /// - Parameters:
    ///   - launcher: The captured launcher token, for example `"codexTeams"` or `"omo"`.
    ///   - sessionId: The session/thread id to fork.
    ///   - executablePath: The captured executable path, if any.
    ///   - arguments: The captured launch argv, including the executable as element zero.
    /// - Returns: `.resolved(argv)` for known wrapper launchers, `.resolved(nil)` for wrappers
    ///   with no fork form, and `.passthrough` for plain agent launchers.
    public func launcherResolution(
        launcher: String?,
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> AgentForkLauncherResolution {
        switch launcher {
        case "claudeTeams":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "cmux")
            var tail = parts.tail
            if tail.first == "claude-teams" { tail.removeFirst() }
            guard let preserved = AgentLaunchSanitizer.preservedClaudeTeamsLaunchArguments(args: tail) else {
                return .resolved(nil)
            }
            return .resolved([parts.executable, "claude-teams", "--resume", sessionId, "--fork-session"] + preserved)
        case "codexTeams":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "cmux")
            var tail = parts.tail
            if tail.first == "codex-teams" { tail.removeFirst() }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "codex-fork-replay", args: tail) else {
                return .resolved(nil)
            }
            return .resolved([parts.executable, "codex-teams", "fork", sessionId] + preserved)
        case "omo":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "cmux")
            var tail = parts.tail
            if tail.first == "omo" { tail.removeFirst() }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: tail) else {
                return .resolved(nil)
            }
            return .resolved([parts.executable, "omo", "--session", sessionId, "--fork"] + preserved)
        case "omx", "omc":
            return .resolved(nil)
        default:
            return .passthrough
        }
    }

    /// Builds the fork argv for a built-in agent kind.
    ///
    /// - Parameters:
    ///   - kind: The agent kind identifier, for example `"codex"` or `"opencode"`.
    ///   - sessionId: The session/thread id to fork.
    ///   - executablePath: The captured executable path, if any.
    ///   - arguments: The captured launch argv, including the executable as element zero.
    /// - Returns: The fork argv when the kind has a sanitizer-approved fork form, or `nil`.
    public func builtInKind(
        kind: String,
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> [String]? {
        switch kind {
        case "claude":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "claude")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: parts.tail) else {
                return nil
            }
            return ["claude", "--resume", sessionId, "--fork-session"] + preserved
        case "codex":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "codex")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "codex-fork-replay", args: parts.tail) else {
                return nil
            }
            let replayExecutable = codexReplayExecutable(
                capturedExecutable: parts.executable,
                launchTail: parts.tail
            )
            return [replayExecutable, "fork", sessionId] + preserved
        case "opencode":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "opencode")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: parts.tail) else {
                return nil
            }
            return [parts.executable, "--session", sessionId, "--fork"] + preserved
        case "pi":
            return withSessionFork(
                kind: "pi",
                executable: "pi",
                sessionId: sessionId,
                executablePath: executablePath,
                arguments: arguments
            )
        case "omp":
            return withSessionFork(
                kind: "omp",
                executable: "omp",
                sessionId: sessionId,
                executablePath: executablePath,
                arguments: arguments
            )
        default:
            return nil
        }
    }

    private func withSessionFork(
        kind: String,
        executable fallbackExecutable: String,
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> [String]? {
        let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: fallbackExecutable)
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: kind, args: parts.tail) else { return nil }
        return [parts.executable, "--session", sessionId, "--fork"] + preserved
    }

    private func commandParts(
        executablePath: String?,
        arguments: [String],
        fallbackExecutable: String
    ) -> (executable: String, tail: [String]) {
        let executable = normalized(executablePath) ?? normalized(arguments.first) ?? fallbackExecutable
        let tail = arguments.isEmpty ? [] : Array(arguments.dropFirst())
        return (executable, tail)
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
