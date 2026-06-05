import Foundation

/// cmux's canonical Claude Code hook settings document.
///
/// A cmux-launched `claude` process is wrapped by `Resources/bin/claude`, which
/// passes `--settings <json>` so Claude Code's lifecycle events
/// (SessionStart / Stop / Notification / …) fire back into cmux via the
/// `cmux hooks claude <event>` bridge. ``settingsJSON`` is the Swift source of
/// truth for that document, so the native resume path
/// (``AgentResumeArgv/builtInKind(kind:sessionId:executablePath:arguments:)``)
/// can re-apply cmux's *current* hooks after the captured (possibly stale) hook
/// `--settings` is stripped during resume sanitization.
///
/// > Important: The inline `HOOKS_JSON` literal in `Resources/bin/claude` is the
/// > fresh-launch sibling of this constant. The two must stay in sync: any change
/// > to the hook wiring belongs in both places (or neither resumed nor freshly
/// > launched sessions will agree on which hooks fire). See
/// > https://github.com/manaflow-ai/cmux/issues/5427.
///
/// The hook commands invoke `"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}"`, which resolves
/// to cmux's bundled CLI when the wrapper exported `CMUX_CLAUDE_HOOK_CMUX_BIN`
/// (fresh launch) and otherwise falls back to `cmux` on `PATH` (resume, where the
/// command runs the real `claude` binary directly and bypasses the wrapper). cmux
/// terminals prepend the bundled `bin` directory to `PATH`, so the bare `cmux`
/// fallback resolves to the same CLI either way.
///
/// ## Example
///
/// Re-apply cmux's hooks when resuming a captured `claude` launch:
///
/// ```swift
/// let argv = ["claude", "--resume", sessionId, "--settings", ClaudeHookSettings.settingsJSON]
///     + preservedUserArguments
/// ```
public struct ClaudeHookSettings: Sendable, Equatable {
    /// Creates a value. The type holds no state; it namespaces the canonical
    /// settings document and is a value so it composes with dependency injection
    /// rather than a shared singleton.
    public init() {}

    /// The canonical Claude Code `--settings` JSON cmux applies to wire Claude's
    /// lifecycle hooks to the `cmux hooks claude <event>` bridge.
    ///
    /// Kept verbatim in sync with the `HOOKS_JSON` literal in
    /// `Resources/bin/claude`.
    public static let settingsJSON: String = #"{"preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\" hooks claude session-start","timeout":10}]}],"Stop":[{"matcher":"","hooks":[{"type":"command","command":"\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\" hooks claude stop","timeout":10}]},{"matcher":"","hooks":[{"type":"command","command":"\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\" hooks feed --source claude","timeout":10,"async":true}]}],"SubagentStop":[{"matcher":"","hooks":[{"type":"command","command":"\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\" hooks feed --source claude","timeout":10,"async":true}]}],"SessionEnd":[{"matcher":"","hooks":[{"type":"command","command":"\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\" hooks claude session-end","timeout":1}]}],"Notification":[{"matcher":"","hooks":[{"type":"command","command":"\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\" hooks claude notification","timeout":10}]}],"UserPromptSubmit":[{"matcher":"","hooks":[{"type":"command","command":"\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\" hooks claude prompt-submit","timeout":10}]}],"PreToolUse":[{"matcher":"CronCreate","hooks":[{"type":"command","command":"\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\" hooks claude cron-create-guard","timeout":5}]},{"matcher":"","hooks":[{"type":"command","command":"\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\" hooks claude pre-tool-use","timeout":5,"async":true}]}],"PermissionRequest":[{"matcher":"","hooks":[{"type":"command","command":"\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\" hooks feed --source claude","timeout":125}]}]}}"#
}
