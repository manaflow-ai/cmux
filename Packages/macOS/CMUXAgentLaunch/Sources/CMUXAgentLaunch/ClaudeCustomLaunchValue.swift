import Foundation

/// Classifies the user-configured "Claude Binary Path" setting value
/// (Settings › Automation › Claude Binary Path, `CMUX_CUSTOM_CLAUDE_PATH`).
///
/// A `claude` defined as a shell function/wrapper in the user's rc file is
/// invisible to cmux's non-interactive launch paths, so the setting also
/// accepts a launch *command*: a `/bin/sh` snippet that receives the agent
/// arguments as `"$@"` (with `$0` set to `claude`), e.g.
/// `/bin/zsh -lic 'claude "$@"' claude "$@"`.
/// https://github.com/manaflow-ai/cmux/issues/7035
///
/// Classification rules (must stay in sync with the bash mirror
/// `cmux_claude_custom_launch_command` in `Resources/bin/cmux-claude-wrapper`):
/// 1. An existing executable file keeps binary mode. This check runs first so
///    plain binary paths — including paths containing spaces — behave exactly
///    as before.
/// 2. Otherwise a value containing the literal `$@` argument reference is a
///    launch command. The marker is required, never inferred: a working
///    command must forward the agent arguments via `"$@"` anyway, and
///    inferring command mode from whitespace/metacharacters would turn a
///    stale spaced path into a hard exec failure and silently drop every
///    argument from a value like `$HOME/bin/claude`.
/// 3. Anything else (e.g. a stale path to a deleted binary) keeps the
///    historical silent fallback to PATH resolution.
///
/// The type is a stateless value; construct one at the call site
/// (`ClaudeCustomLaunchValue()`) rather than reaching through a static
/// namespace, per the package design discipline.
public struct ClaudeCustomLaunchValue: Sendable, Equatable {
    /// How a configured Claude Binary Path value should be launched.
    public enum Classification: Sendable, Equatable {
        /// The value is an existing executable file; exec it directly.
        case executablePath(String)
        /// The value is a `/bin/sh` command receiving the agent arguments as `"$@"`.
        case shellCommand(String)
        /// The value is empty or unusable; fall back to PATH resolution.
        case pathFallback
    }

    /// Environment variable exported for the duration of a custom launch
    /// command, so a command whose inner `claude` re-enters cmux's shim or
    /// wrapper falls back to normal PATH resolution instead of looping.
    ///
    /// The variable intentionally leaks into the launched Claude process (the
    /// wrapper cannot observe the boundary where the user's command hands off
    /// to the real binary), so descendant `claude` invocations inside that
    /// session resolve through PATH rather than the custom command.
    public static let commandActiveGuardEnvironmentKey = "CMUX_CLAUDE_CUSTOM_COMMAND_ACTIVE"

    /// Creates a classifier. The type holds no state.
    public init() {}

    /// Classifies `configuredValue`, probing the filesystem through
    /// `isExecutableFile` (which must be true only for existing,
    /// non-directory, executable files).
    public func classify(
        configuredValue: String?,
        isExecutableFile: (String) -> Bool
    ) -> Classification {
        guard
            let trimmed = configuredValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else {
            return .pathFallback
        }
        if isExecutableFile(trimmed) {
            return .executablePath(trimmed)
        }
        if trimmed.contains("$@") {
            return .shellCommand(trimmed)
        }
        return .pathFallback
    }

    /// The argv that runs a ``Classification/shellCommand(_:)`` value:
    /// `/bin/sh -c <command> claude <arguments…>`, so the command sees the
    /// agent arguments as `"$@"` and `$0` as `claude`.
    public func shellCommandArgv(command: String, arguments: [String]) -> [String] {
        ["/bin/sh", "-c", command, "claude"] + arguments
    }
}
