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

    /// The shell token that resolves cmux's `claude` wrapper at exec time.
    ///
    /// The claude resume/fork argv emits a bare `claude` executable and relies on
    /// cmux's `claude` wrapper (which re-injects the hook `--settings` on `--resume`)
    /// being reachable. Inside cmux terminals the wrapper is reached two ways: a
    /// `claude()` shell function and a per-surface PATH shim, both installed by the
    /// shell integration. Neither survives the close-&-reopen restore launcher, which
    /// runs the resumed agent in a fresh `$SHELL -lic` login-interactive shell where
    /// the integration is not active (the user's login profile clobbers `ZDOTDIR`/`PATH`).
    /// Worse, the resume command is `env … claude …`, and `env` resolves `claude` via
    /// `execvp` — bypassing the shell function entirely — so even re-sourcing the
    /// integration would not help an `env`-prefixed invocation whose `PATH` was rebuilt.
    ///
    /// `CMUX_CLAUDE_WRAPPER_SHIM` is a *managed* terminal environment variable (set by
    /// `TerminalStartupEnvironment` / `GhosttyTerminalView`) pointing at the per-surface
    /// shim that execs the wrapper. It is inherited by every descendant shell regardless
    /// of `PATH`/function shadowing, so resolving the claude executable through it makes
    /// the executed resume command route through the wrapper (hooks fire) inside the
    /// `-lic` launcher. https://github.com/manaflow-ai/cmux/issues/5639
    ///
    /// The token guards on `[ -x … ]`, not bare `${VAR:-claude}` expansion: macOS reaps
    /// idle files under the temporary directory after ~3 days, and a long-idle surface
    /// can hold the env var while the shim file is gone. Parameter expansion alone would
    /// exec the dead path and hard-fail resume; the executability guard degrades to bare
    /// `claude` (PATH resolution — hooks lost but resume works), the same graceful
    /// fallback used when the variable is unset outside cmux.
    ///
    /// The token is POSIX command substitution, which fish and csh/tcsh reject, so any
    /// command containing it must reach those shells wrapped via
    /// ``portableClaudeResumeShellCommand(posixCommand:)``.
    public static let claudeWrapperShellExecutableToken =
        "\"$([ -x \"${CMUX_CLAUDE_WRAPPER_SHIM:-}\" ] && printf '%s' \"$CMUX_CLAUDE_WRAPPER_SHIM\" || printf claude)\""

    /// Wraps a rendered claude resume/fork command so it parses in any login shell.
    ///
    /// ``claudeWrapperShellExecutableToken`` is POSIX-only syntax, but the rendered
    /// command is not always parsed by a POSIX shell: the restore launcher dispatches it
    /// through the user's `$SHELL` (`TerminalStartupReturnShellScript` runs
    /// `"$_cmux_resume_shell" -c <command>` for its `csh|tcsh` and `*` branches), and the
    /// session-index resume command is typed into — and copy-pasted into — the user's
    /// interactive shell. fish rejects `${…}` outright and csh/tcsh have no `:-` modifier,
    /// so the raw token turns claude resume into a hard parse error there, even though the
    /// pre-token command was valid in those shells.
    ///
    /// `/bin/sh -c '<command>'` is the one spelling every dispatching shell parses
    /// identically (plain words plus single-quote escaping, which zsh, bash, fish, csh,
    /// and tcsh all accept): the user's shell still sources its own config (env exports
    /// apply), `sh` inherits `CMUX_CLAUDE_WRAPPER_SHIM` from the managed terminal
    /// environment and resolves the token, and outside cmux the unset variable still
    /// falls back to bare `claude`. Callers wrap the fully rendered POSIX command
    /// *before* prepending any working-directory guard, so cd-prefix rewriting keeps
    /// composing on the outside. https://github.com/manaflow-ai/cmux/issues/5639
    public static func portableClaudeResumeShellCommand(posixCommand: String) -> String {
        "/bin/sh -c " + posixSingleQuoted(posixCommand)
    }

    /// Renders claude command `parts` through ``renderingClaudeWrapperExecutable(parts:quote:)``
    /// and joins them, wrapping via ``portableClaudeResumeShellCommand(posixCommand:)`` only
    /// when the wrapper token was actually substituted.
    ///
    /// Claude-launcher resumes that resolve to cmux's own CLI (`cmux claude-teams --resume …`)
    /// emit no bare `claude` executable: they were already portable quoted words, the cmux
    /// binary re-injects hooks itself, and wrapping them would only obscure the command. The
    /// `/bin/sh -c` layer exists solely to make the POSIX-only token parse in non-POSIX
    /// shells, so it is applied exactly when the token is present.
    public static func renderedPortableClaudeResumeShellCommand(
        parts: [String],
        quote: (String) -> String
    ) -> String {
        let rendered = renderingClaudeWrapperExecutable(parts: parts, quote: quote)
        let joined = rendered.joined(separator: " ")
        guard rendered.contains(claudeWrapperShellExecutableToken) else { return joined }
        return portableClaudeResumeShellCommand(posixCommand: joined)
    }

    /// Renders shell command `parts` to quoted tokens, substituting
    /// ``claudeWrapperShellExecutableToken`` for the first bare `claude` executable token.
    ///
    /// Callers pass the full command parts (any leading `env VAR=value …` prefix plus the
    /// resume argv) and their own quoting function. Only the first element equal to `claude`
    /// — the wrapper executable emitted by the claude resume/fork builders — is replaced;
    /// every other token (including any later argument that happens to be the word `claude`)
    /// is quoted normally. Call only for the claude kind. Keeping this in the pure value
    /// layer lets the app resume builder and the cmux-cli surface-restore publisher share one
    /// wrapper-routing seam. https://github.com/manaflow-ai/cmux/issues/5639
    public static func renderingClaudeWrapperExecutable(
        parts: [String],
        quote: (String) -> String
    ) -> [String] {
        var replaced = false
        return parts.map { part in
            if !replaced, part == "claude" {
                replaced = true
                return claudeWrapperShellExecutableToken
            }
            return quote(part)
        }
    }

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
            guard let preserved = AgentLaunchSanitizer.preservedClaudeTeamsLaunchArguments(args: tail) else {
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
    /// cmux injects Claude Code's hook `--settings` from the `cmux-claude-wrapper`,
    /// which re-injects those hooks whenever it sees `--resume`, exactly as it does on
    /// a fresh launch (and it also re-applies the rest of the fresh-launch setup:
    /// `CLAUDE_CONFIG_DIR` normalization, auth-selection env handling, NODE_OPTIONS,
    /// nested-session unset). The captured launch executable, however, is the
    /// *real* claude binary (`CMUX_AGENT_LAUNCH_EXECUTABLE`), so resuming with it
    /// directly bypassed the wrapper and dropped every hook
    /// (https://github.com/manaflow-ai/cmux/issues/5427).
    ///
    /// The argv keeps a bare `claude` executable as its logical value; the wrapper is
    /// reached at render time via ``claudeWrapperShellExecutableToken`` (resolved through
    /// the `CMUX_CLAUDE_WRAPPER_SHIM` managed env var), because relying on the wrapper
    /// being first on `PATH` does not hold inside the `$SHELL -lic` restore launcher
    /// (https://github.com/manaflow-ai/cmux/issues/5639). The captured executable is
    /// intentionally ignored for claude; the wrapper resolves the real binary
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
        guard let executable = normalized(executablePath) ?? normalized(arguments.first),
              !AgentLaunchCaptureTrust.executableLooksLikeShell(executable) else {
            return (fallbackExecutable, [])
        }
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

/// Single-quotes `value` as one POSIX `sh` word, escaping embedded quotes as `'\''`.
private func posixSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
