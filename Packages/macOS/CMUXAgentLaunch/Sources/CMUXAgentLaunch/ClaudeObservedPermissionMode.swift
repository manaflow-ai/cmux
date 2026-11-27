import Foundation

/// Re-applies a hook-observed Claude permission mode to a rebuilt resume/fork argv.
///
/// A mode selected in-session (shift+tab auto-accept, plan mode, bypass toggle) is
/// runtime state, not argv, so no amount of launch-argument preservation can recover
/// it. cmux already observes the live mode from Claude hook payloads
/// (`permission_mode`); the restore builders feed the last-known value back as
/// `--permission-mode <mode>` so a user-owned resume continues in the mode the
/// session actually ended in.
///
/// Trust boundary: this applies ONLY to user-owned session resume/fork — a user
/// restoring their own session is a continuation of their original explicit opt-in.
/// The claude-teams orphan-respawn path (`launcherResolution`) deliberately has no
/// observed-mode input: an orphaned teammate pane whose parent session is gone is
/// not a fresh permission opt-in and must fall back to Claude's own prompts
/// (see `CMUXCLI+TmuxCompatSupport.tmuxClaudeTeamsRespawnEnvironment`).
/// https://github.com/manaflow-ai/cmux/issues/8066
extension AgentResumeArgv {
    /// The `--permission-mode` values the Claude CLI accepts. Observed state is
    /// persisted on disk and rendered into a shell command, so only these exact
    /// values are ever re-emitted; `default` (the hook payload's name for the
    /// normal mode, not a CLI choice) and anything unrecognized are ignored.
    public static let restorableClaudePermissionModes: Set<String> = [
        "acceptEdits",
        "auto",
        "bypassPermissions",
        "dontAsk",
        "manual",
        "plan"
    ]

    /// Returns `argv` with `--permission-mode <observedPermissionMode>` appended
    /// when the observed mode is a recognized non-default mode and the argv does
    /// not already carry an explicit permission flag. Explicit flags preserved
    /// from the original launch (`--permission-mode`, `--permission-mode=…`, or
    /// `--dangerously-skip-permissions`) always win over observed state, so the
    /// two are never emitted together.
    public static func claudeArgvApplyingObservedPermissionMode(
        _ argv: [String],
        observedPermissionMode: String?
    ) -> [String] {
        guard let mode = observedPermissionMode?.trimmingCharacters(in: .whitespacesAndNewlines),
              restorableClaudePermissionModes.contains(mode) else {
            return argv
        }
        let tail = Array(argv.dropFirst())
        guard !AgentLaunchSanitizer.claudeLaunchHasOption("--permission-mode", args: tail),
              !AgentLaunchSanitizer.claudeLaunchHasOption("--dangerously-skip-permissions", args: tail) else {
            return argv
        }
        return argv + ["--permission-mode", mode]
    }
}

extension AgentLaunchSanitizer {
    /// Whether `option` appears as a real option token in a direct-claude argv.
    ///
    /// Mirror of ``claudeTeamsLaunchHasOption(_:args:)`` for the direct claude
    /// policy: value slots are skipped via the policy's option widths, so a
    /// flag-shaped token inside another option's value (e.g.
    /// `--append-system-prompt "--permission-mode"`) is never promoted to an
    /// option. Positionals are skipped, matching the policy's
    /// scan-past-positionals replay boundary.
    static func claudeLaunchHasOption(_ option: String, args: [String]) -> Bool {
        let policy = claudePolicy
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" { return false }
            if !arg.hasPrefix("-") || arg == "-" {
                index += 1
                continue
            }
            if arg == option || arg.hasPrefix(option + "=") { return true }
            index += max(optionWidth(args, index: index, policy: policy), 1)
        }
        return false
    }
}
