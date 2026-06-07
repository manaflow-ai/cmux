import Foundation

/// Builds the argument vector for an agent's resume/continue command.
///
/// This is the single source of truth shared by the app-side resume builder
/// (`AgentResumeCommandBuilder` in the app target) and the standalone `cmux-cli` surface-restore
/// publisher (`agentSurfaceResumeCommand`), so both emit identical resume commands. It is pure value
/// logic over primitives (no `AppKit`, `Process`, or socket), so it is testable in isolation.
///
/// The type is a stateless value; construct one at the call site (`AgentResumeArgv()`) rather than
/// reaching through a static namespace, per the package design discipline.
///
/// Resolution order mirrors the historical app builder: a cmux wrapper launcher
/// (``launcherResolution(launcher:sessionId:executablePath:arguments:)``) is checked first, then the
/// per-kind verb (``builtInKind(kind:sessionId:executablePath:arguments:)``). Callers that also
/// support custom Vault agents slot that resolution between the two.
public struct AgentResumeArgv: Sendable, Equatable {
    /// Creates a resume-argv builder. The type holds no state.
    public init() {}

    /// The result of resolving a cmux wrapper launcher (the `claude-teams` / `codex-teams` / `omo`
    /// style launchers cmux injects), checked before the per-kind verb.
    public enum LauncherResolution: Sendable, Equatable {
        /// The launcher is a cmux wrapper; the associated value is its resume argv, or `nil` when the
        /// wrapper has no resumable form (e.g. one-shot `omx`/`omc`).
        case resolved([String]?)
        /// The launcher is a plain agent executable; fall through to ``builtInKind(kind:sessionId:executablePath:arguments:)``.
        case passthrough
    }

    /// Resolves a resume argv from a cmux wrapper launcher, or ``LauncherResolution/passthrough`` when
    /// the launcher is a plain agent executable.
    ///
    /// - Parameters:
    ///   - launcher: the captured launcher token (e.g. `"claudeTeams"`, `"omo"`), or `nil`.
    ///   - sessionId: the session/thread id to resume.
    ///   - executablePath: the captured executable path, if any.
    ///   - arguments: the captured launch arguments (argv, including the executable as element 0).
    public func launcherResolution(
        launcher: String?,
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> LauncherResolution {
        switch launcher {
        case "claudeTeams":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "cmux")
            var tail = parts.tail
            if tail.first == "claude-teams" { tail.removeFirst() }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: tail) else {
                return .resolved(nil)
            }
            return .resolved([parts.executable, "claude-teams", "--resume", sessionId] + preserved)
        case "codexTeams":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "cmux")
            var tail = parts.tail
            if tail.first == "codex-teams" { tail.removeFirst() }
            guard let preserved = AgentLaunchSanitizer.preservedCodexForkArguments(args: tail) else {
                return .resolved(nil)
            }
            return .resolved([parts.executable, "codex-teams", "resume", sessionId] + preserved)
        case "omo":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "cmux")
            var tail = parts.tail
            if tail.first == "omo" { tail.removeFirst() }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: tail) else {
                return .resolved(nil)
            }
            return .resolved([parts.executable, "omo", "--session", sessionId] + preserved)
        case "omx", "omc":
            return .resolved(nil)
        default:
            return .passthrough
        }
    }

    /// Builds the resume argv for a built-in agent kind, or `nil` if the kind is unknown or its launch
    /// arguments cannot be preserved.
    ///
    /// - Parameters:
    ///   - kind: the agent's raw kind identifier (e.g. `"claude"`, `"codex"`, `"hermes-agent"`).
    ///   - sessionId: the session/thread id to resume.
    ///   - executablePath: the captured executable path, if any.
    ///   - arguments: the captured launch arguments (argv, including the executable as element 0).
    public func builtInKind(
        kind: String,
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> [String]? {
        switch kind {
        case "claude":
            return claudeResumeArgv(sessionId: sessionId, executablePath: executablePath, arguments: arguments)
        case "codex":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "codex")
            guard let preserved = AgentLaunchSanitizer.preservedCodexForkArguments(args: parts.tail) else { return nil }
            return [parts.executable, "resume", sessionId] + preserved
        case "grok":
            return withOption("grok", executable: "grok", option: "-r", sessionId: sessionId, executablePath: executablePath, arguments: arguments)
        case "pi":
            return withOption("pi", executable: "pi", option: "--session", sessionId: sessionId, executablePath: executablePath, arguments: arguments)
        case "omp":
            return withOption("omp", executable: "omp", option: "--session", sessionId: sessionId, executablePath: executablePath, arguments: arguments)
        case "amp":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "amp")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "amp", args: parts.tail) else { return nil }
            return [parts.executable, "threads", "continue"] + preserved + [sessionId]
        case "cursor":
            return withOption("cursor", executable: "cursor-agent", option: "--resume", sessionId: sessionId, executablePath: executablePath, arguments: arguments)
        case "gemini":
            return withOption("gemini", executable: "gemini", option: "--resume", sessionId: sessionId, executablePath: executablePath, arguments: arguments)
        case "kiro":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "kiro-cli")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "kiro", args: parts.tail) else { return nil }
            return [parts.executable, "chat", "--resume-id", sessionId] + preserved
        case "antigravity":
            return withOption("antigravity", executable: "agy", option: "--conversation", sessionId: sessionId, executablePath: executablePath, arguments: arguments)
        case "opencode":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "opencode")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: parts.tail) else { return nil }
            return [parts.executable, "--session", sessionId] + preserved
        case "rovodev":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "acli")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "rovodev", args: parts.tail) else { return nil }
            return [parts.executable, "rovodev", "run", "--restore", sessionId] + preserved
        case "hermes-agent":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "hermes")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "hermes-agent", args: parts.tail) else { return nil }
            return [parts.executable] + preserved + ["--resume", sessionId]
        case "copilot":
            return withOption("copilot", executable: "copilot", option: "--resume", sessionId: sessionId, executablePath: executablePath, arguments: arguments)
        case "codebuddy":
            return withOption("codebuddy", executable: "codebuddy", option: "--resume", sessionId: sessionId, executablePath: executablePath, arguments: arguments)
        case "factory":
            return withOption("factory", executable: "droid", option: "--resume", sessionId: sessionId, executablePath: executablePath, arguments: arguments)
        case "qoder":
            return withOption("qoder", executable: "qodercli", option: "--resume", sessionId: sessionId, executablePath: executablePath, arguments: arguments)
        default:
            return nil
        }
    }

    /// Builds the claude resume argv, routing it through cmux's `claude` wrapper
    /// so cmux hooks fire on the resumed session.
    ///
    /// cmux injects Claude Code's hook `--settings` from the `Resources/bin/claude`
    /// wrapper, which is first on `PATH` inside cmux terminals. The wrapper
    /// re-injects those hooks whenever it sees `--resume`, exactly as it does on a
    /// fresh launch (and it also re-applies the rest of the fresh-launch setup:
    /// `CLAUDE_CONFIG_DIR` normalization, auth-selection env handling, NODE_OPTIONS,
    /// nested-session unset). The captured launch executable, however, is the
    /// *real* claude binary (`CMUX_AGENT_LAUNCH_EXECUTABLE`), so resuming with it
    /// directly bypassed the wrapper and dropped every hook
    /// (https://github.com/manaflow-ai/cmux/issues/5427).
    ///
    /// Forcing the executable to the bare `claude` wrapper is the same thing the
    /// session-index resume builder (`SessionEntry.resumeCommand`) already does,
    /// so both resume paths now share one injection point. The captured executable
    /// is intentionally ignored for claude; the wrapper resolves the real binary
    /// (honouring `CMUX_CUSTOM_CLAUDE_PATH`).
    private func claudeResumeArgv(
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> [String]? {
        let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "claude")
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: parts.tail) else {
            return nil
        }
        return ["claude", "--resume", sessionId] + preserved
    }

    private func withOption(
        _ kind: String,
        executable fallbackExecutable: String,
        option: String,
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> [String]? {
        let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: fallbackExecutable)
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: kind, args: parts.tail) else { return nil }
        return [parts.executable, option, sessionId] + preserved
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
