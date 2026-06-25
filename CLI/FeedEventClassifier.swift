import Foundation

/// Classifies a raw agent hook event into our wire `hook_event_name` plus an
/// `isActionable` flag.
///
/// This is the single source of truth behind both the running `cmux` CLI
/// (`cmux hooks feed …`) and the `FeedEventClassificationTests` regression
/// suite — the file is compiled into the `cmux-cli` target and the
/// `cmuxTests` target so the pure decision can be unit-tested without
/// launching the app or running the CLI as a subprocess.
///
/// The mapping is driven by an explicit, typed registry
/// (``feedEventSemantic(source:event:)``) keyed on `(source, event)` rather
/// than by pattern-matching raw event-name strings. Notification eligibility
/// is derived only from the resolved ``FeedEventSemantic``, so a
/// tool-*starting* lifecycle event can never be mistaken for an approval
/// request — and unknown / future event names default to non-actionable
/// telemetry that never notifies. Conflating a tool-start with an approval
/// is the bug behind https://github.com/manaflow-ai/cmux/issues/4985.
struct FeedEventClassifier {
    /// Classifies a raw agent hook event into our wire `hook_event_name`
    /// plus an `isActionable` flag that drives whether the Feed bridge
    /// blocks waiting for a user decision (and whether `FeedCoordinator`
    /// posts a "needs approval" notification).
    ///
    /// - Parameters:
    ///   - source: The agent id that emitted the event (`claude`, `codex`,
    ///     `hermes-agent`, …). Unregistered sources use the generic table.
    ///   - event: The agent's raw hook event name.
    ///   - toolName: The tool the event refers to, used only for the two
    ///     tool-dependent semantics.
    /// - Returns: The wire `hook_event_name` and whether the event is
    ///   Feed-actionable (blocks + may notify).
    static func classify(
        source: String,
        event: String,
        toolName: String
    ) -> (String, Bool) {
        let semantic = feedEventSemantic(source: source, event: event)
        return wireMapping(for: semantic, source: source, toolName: toolName)
    }

    /// User-attention semantic of a hook/feed event, independent of the
    /// agent-specific raw event name. Notifications and blocking waits are
    /// keyed off this — never off raw event-name string matching — so the
    /// same misclassification cannot recur as new event names are added.
    private enum FeedEventSemantic {
        /// A real approval is pending; the user must approve/deny. Drives
        /// the blocking Feed wait and the "needs approval" notification.
        /// Resolved against the tool name so Claude's `ExitPlanMode` /
        /// `AskUserQuestion` approvals route to their dedicated kinds.
        case approvalRequest
        /// A tool is about to run but no approval is pending. Telemetry
        /// only. Used by agents that expose a *separate* approval event
        /// (Claude, Codex, Hermes) so their pre-tool hook never escalates.
        case toolStart
        /// A tool is about to run and the agent has *no* dedicated approval
        /// event, so a side-effecting tool is escalated to an approval and
        /// read-only tools stay telemetry. Resolved against the tool name.
        case toolStartMaybeApproval
        /// A tool finished. Telemetry only.
        case toolEnd
        /// The agent is about to compact conversation context. Telemetry only.
        case preCompact
        /// The agent finished compacting conversation context. Telemetry only.
        case postCompact
        /// A new turn / prompt started. Telemetry only.
        case promptSubmit
        /// A subagent started. Telemetry only.
        case subagentStart
        /// The agent finished responding. Telemetry only.
        case response
        /// A subagent finished responding. Telemetry only.
        case subagentResponse
        case sessionStart
        case sessionEnd
        /// A generic status/notification event. Telemetry only — real
        /// approval banners for these agents fire through the dedicated
        /// `notification` hook subcommand, not the feed path.
        case statusNotification
        /// Unknown / unregistered event. Safe default: telemetry only,
        /// never actionable, never notifies.
        case unknown
    }

    /// Resolves the semantic for a `(source, event)` pair. A registered
    /// source uses its own table (unmatched events fall to ``FeedEventSemantic/unknown``);
    /// unregistered sources use the generic table.
    private static func feedEventSemantic(
        source: String,
        event: String
    ) -> FeedEventSemantic {
        let table = feedEventSemanticRegistry[source] ?? genericFeedEventSemantics
        return table[event] ?? .unknown
    }

    /// Tool names that carry their own dedicated approval wire event rather
    /// than the generic `PermissionRequest`. Returns the actionable wire
    /// mapping for such a tool, or `nil` for ordinary tools.
    private static func dedicatedApprovalEvent(for toolName: String) -> (String, Bool)? {
        switch toolName {
        case "ExitPlanMode": return ("ExitPlanMode", true)
        case "AskUserQuestion": return ("AskUserQuestion", true)
        default: return nil
        }
    }

    /// Maps a resolved semantic to the wire `hook_event_name` plus the
    /// `isActionable` flag, using `toolName` for the two tool-dependent
    /// semantics.
    private static func wireMapping(
        for semantic: FeedEventSemantic,
        source: String,
        toolName: String
    ) -> (String, Bool) {
        switch semantic {
        case .approvalRequest:
            return dedicatedApprovalEvent(for: toolName) ?? ("PermissionRequest", true)
        case .toolStartMaybeApproval:
            if let dedicated = dedicatedApprovalEvent(for: toolName) {
                return dedicated
            }
            // Any tool that can mutate the environment surfaces as a
            // permission request so the user can approve/deny from the
            // Feed sidebar. Read-only tools stay non-actionable
            // telemetry so we don't flood the Actionable view.
            if Self.isSideEffectingTool(toolName, source: source) {
                return ("PermissionRequest", true)
            }
            return ("PreToolUse", false)
        case .toolStart:
            return ("PreToolUse", false)
        case .toolEnd:
            return ("PostToolUse", false)
        case .preCompact:
            return ("PreCompact", false)
        case .postCompact:
            return ("PostCompact", false)
        case .promptSubmit:
            return ("UserPromptSubmit", false)
        case .subagentStart:
            return ("SubagentStart", false)
        case .response:
            return ("Stop", false)
        case .subagentResponse:
            return ("SubagentStop", false)
        case .sessionStart:
            return ("SessionStart", false)
        case .sessionEnd:
            return ("SessionEnd", false)
        case .statusNotification:
            return ("Notification", false)
        case .unknown:
            // Safe default: telemetry, no approval, no notification.
            return ("PreToolUse", false)
        }
    }

    /// Per-agent event-semantic tables. Each entry is the source of truth
    /// for that agent's `(event) -> semantic` mapping; events absent here
    /// resolve to ``FeedEventSemantic/unknown``.
    ///
    /// The key distinction the registry encodes: agents with a *dedicated*
    /// approval event (Claude `PermissionRequest`, Codex `PermissionRequest`,
    /// Hermes `pre_approval_request`) classify their pre-tool event as
    /// ``FeedEventSemantic/toolStart`` (always telemetry). Agents whose only
    /// signal is the pre-tool event (gemini, copilot, …, handled by
    /// ``genericFeedEventSemantics``) use
    /// ``FeedEventSemantic/toolStartMaybeApproval`` so side-effecting tools
    /// still escalate. Conflating the two is the bug behind #4985.
    private static let feedEventSemanticRegistry: [String: [String: FeedEventSemantic]] = [
        "claude": [
            "PermissionRequest": .approvalRequest,
            "PreToolUse": .toolStart,
            "PostToolUse": .toolEnd,
            "PreCompact": .preCompact,
            "PostCompact": .postCompact,
            "UserPromptSubmit": .promptSubmit,
            "SessionStart": .sessionStart,
            "SessionEnd": .sessionEnd,
            "Stop": .response,
            "SubagentStart": .subagentStart,
            "SubagentStop": .subagentResponse,
            "Notification": .statusNotification,
        ],
        "codex": [
            // Codex runs PermissionRequest hooks before its own approval
            // reviewer. Treat this as telemetry so "Approve for me" can still
            // use Codex's auto-review path instead of blocking on cmux Feed.
            "PermissionRequest": .toolStart,
            "permission_request": .toolStart,
            "PreToolUse": .toolStart,
            "pre_tool_use": .toolStart,
            "beforeShellExecution": .toolStart,
            "PostToolUse": .toolEnd,
            "post_tool_use": .toolEnd,
            "PreCompact": .preCompact,
            "pre_compact": .preCompact,
            "PostCompact": .postCompact,
            "post_compact": .postCompact,
            "UserPromptSubmit": .promptSubmit,
            "user_prompt_submit": .promptSubmit,
            "SessionStart": .sessionStart,
            "session_start": .sessionStart,
            "SessionEnd": .sessionEnd,
            "session_end": .sessionEnd,
            "Stop": .response,
            "stop": .response,
            "SubagentStart": .subagentStart,
            "subagent_start": .subagentStart,
            "SubagentStop": .subagentResponse,
            "subagent_stop": .subagentResponse,
            "Notification": .statusNotification,
            "notification": .statusNotification,
        ],
        "hermes-agent": [
            // `pre_tool_call` is a tool *starting* — Hermes raises a
            // separate `pre_approval_request` for real approvals, so this
            // must stay telemetry even for side-effecting tools (#4985).
            "pre_tool_call": .toolStart,
            "post_tool_call": .toolEnd,
            // The approval banner for Hermes fires through the dedicated
            // `notification` hook subcommand; on the feed path this stays a
            // non-blocking notification to avoid a duplicate banner.
            "pre_approval_request": .statusNotification,
            "post_approval_response": .statusNotification,
            "pre_llm_call": .promptSubmit,
            "post_llm_call": .response,
            "on_session_start": .sessionStart,
            "on_session_reset": .sessionStart,
            "on_session_end": .sessionEnd,
            "on_session_finalize": .sessionEnd,
        ],
        // Kiro emits camelCase hook events and has no dedicated approval
        // event, so its pre-tool event escalates side-effecting tools to an
        // approval (resolved against the kiro tool aliases in
        // ``isSideEffectingTool``). Registering kiro explicitly is required:
        // its lowercase event names are absent from
        // ``genericFeedEventSemantics`` and would otherwise resolve to
        // ``FeedEventSemantic/unknown`` (non-actionable), silently dropping
        // every kiro approval.
        "kiro": [
            "preToolUse": .toolStartMaybeApproval,
            "postToolUse": .toolEnd,
            "userPromptSubmit": .promptSubmit,
            "agentSpawn": .sessionStart,
            "stop": .response,
        ],
    ]

    /// Fallback table for agents without a dedicated entry in
    /// ``feedEventSemanticRegistry``. These agents expose only a pre-tool
    /// event, so it carries ``FeedEventSemantic/toolStartMaybeApproval``.
    private static let genericFeedEventSemantics: [String: FeedEventSemantic] = [
        "PreToolUse": .toolStartMaybeApproval,
        "beforeShellExecution": .toolStartMaybeApproval,
        "PermissionRequest": .approvalRequest,
        "PostToolUse": .toolEnd,
        "PreCompact": .preCompact,
        "PostCompact": .postCompact,
        "UserPromptSubmit": .promptSubmit,
        "SessionStart": .sessionStart,
        "SessionEnd": .sessionEnd,
        "Stop": .response,
        "SubagentStart": .subagentStart,
        "SubagentStop": .subagentResponse,
        "Notification": .statusNotification,
    ]

    /// Tools that mutate state and deserve a user-visible approve/
    /// deny prompt in Feed. Keyed on the canonical tool names Claude,
    /// Codex, and similar agents emit. Read-only tools (Read, Grep,
    /// Glob, Task, WebFetch, WebSearch, LS, TodoWrite, …) are
    /// intentionally excluded.
    private static let sideEffectingTools: Set<String> = [
        "Bash",
        "Write",
        "Edit",
        "MultiEdit",
        "NotebookEdit",
        "apply_patch",   // Codex
        "shell",         // Codex / other agents
        "terminal",      // Hermes Agent
        "run_command",   // Antigravity
        "write_to_file",
        "replace_file_content",
        "multi_replace_file_content",
        "manage_task",
        "schedule",
        "ask_permission",
        "invoke_subagent",
        "define_subagent",
        "manage_subagents",
        "generate_image",
    ]

    /// Kiro emits lowercase / internal tool names (`fs_write`,
    /// `execute_bash`, `use_aws`, …) absent from ``sideEffectingTools``.
    /// Matched case-insensitively, but only for the `kiro` source, so another
    /// agent's lowercase tool name is never broadened into an approval prompt.
    private static let kiroSideEffectingToolAliases: Set<String> = [
        "bash",
        "write",
        "edit",
        "multiedit",
        "notebookedit",
        "apply_patch",
        "shell",
        "execute_bash",
        "fs_write",
        "use_aws",
        "aws",
        "terminal",
        "run_command",
        "write_to_file",
        "replace_file_content",
        "multi_replace_file_content",
        "manage_task",
        "schedule",
        "ask_permission",
        "invoke_subagent",
        "define_subagent",
        "manage_subagents",
        "generate_image",
    ]

    /// Whether a tool mutates state and deserves an approval prompt. Exact
    /// match against ``sideEffectingTools`` for every source; the `kiro`
    /// source additionally matches its case-insensitive internal aliases.
    /// Kept source-scoped so another agent's lowercase tool name is not
    /// escalated into an approval.
    static func isSideEffectingTool(_ toolName: String, source: String) -> Bool {
        guard !toolName.isEmpty else { return false }
        if sideEffectingTools.contains(toolName) {
            return true
        }
        if source == "kiro" {
            return kiroSideEffectingToolAliases.contains(toolName.lowercased())
        }
        return false
    }
}

/// Semantic category of a Claude Code `Notification` hook event, derived from
/// its signal + message. Separate from the display `(subtitle, body)` so the
/// hook handler can decide whether to pull the user's attention without
/// branching on localized strings.
enum ClaudeNotificationKind: Equatable, Sendable {
    case permission
    case error
    case completed
    case waiting
    case attention

    /// Whether this notification warrants the "Needs input" sidebar badge +
    /// bell on its own. Idle `waiting` and `completed` notifications are
    /// informational: Claude Code emits the idle "Claude is waiting for your
    /// input" Notification ~60s after a turn ends even when nothing is
    /// blocked, so flagging it as needs-input is a false alarm (most visibly
    /// under `--dangerously-skip-permissions`, where it is the only
    /// Notification that ever fires). A genuinely pending block is recognized
    /// separately by the handler via the session's current lifecycle, so a
    /// real question/plan still raises the badge.
    var raisesNeedsInput: Bool {
        switch self {
        case .permission, .error, .attention:
            return true
        case .completed, .waiting:
            return false
        }
    }
}

extension FeedEventClassifier {
    /// Pure classification of a Claude `Notification` into a
    /// ``ClaudeNotificationKind``. Mirrors the keyword/cue order the display
    /// classifier uses so the kind and the shown subtitle never disagree.
    static func claudeNotificationKind(signal: String, message: String) -> ClaudeNotificationKind {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve")
            || lower.contains("approval") || lower.contains("permission_prompt") {
            return .permission
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            return .error
        }
        if containsCompletionCue(lower) {
            return .completed
        }
        if containsWaitingCue(lower) {
            return .waiting
        }
        return .attention
    }

    /// Tokenizes on any non-alphanumeric run; shared by the cue checks.
    static func notificationCueTokens(_ lowercasedText: String) -> [Substring] {
        lowercasedText.split { !$0.isLetter && !$0.isNumber }
    }

    static func containsCompletionCue(_ lowercasedText: String) -> Bool {
        notificationCueTokens(lowercasedText).contains { token in
            token == "done"
                || token == "succeed"
                || token == "succeeded"
                || token.hasPrefix("complet")
                || token.hasPrefix("finish")
                || token.hasPrefix("success")
        }
    }

    static func containsWaitingCue(_ lowercasedText: String) -> Bool {
        let tokens = notificationCueTokens(lowercasedText)
        for (index, token) in tokens.enumerated() {
            let previous = index > 0 ? tokens[index - 1] : nil
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if token == "idle" {
                return true
            }
            if token == "wait" || token == "waiting" || token == "awaiting" {
                return true
            }
            if token == "prompt", previous == "idle" || previous == "input" || previous == "user" {
                return true
            }
            if token == "input" {
                if previous == "need" || previous == "needs" || previous == "needed"
                    || previous == "require" || previous == "requires" || previous == "required"
                    || previous == "request" || previous == "requests" || previous == "requested"
                    || previous == "wait" || previous == "waiting" || previous == "awaiting"
                    || previous == "user" || previous == "your"
                    || next == "needed" || next == "required" || next == "requested" {
                    return true
                }
            }
            if token == "question", lowercasedText.contains("?") || tokens.contains(where: {
                $0 == "answer" || $0 == "respond" || $0 == "response" || $0 == "reply"
                    || $0 == "choose" || $0 == "confirm" || $0 == "continue"
            }) {
                return true
            }
        }
        return false
    }
}
