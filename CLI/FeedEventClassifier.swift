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
/// Resolved user-attention outcome for one raw agent hook event on the
/// Feed bridge path.
struct FeedEventClassification: Equatable {
    /// The wire `hook_event_name` forwarded to the app via `feed.push`.
    let hookEventName: String
    /// Whether the Feed bridge blocks waiting for a user decision (and the
    /// app may post an actionable approval card + banner).
    let isActionable: Bool
    /// The agent is blocked waiting for the user in its OWN approval UI
    /// (e.g. Codex's approval reviewer). The feed event stays non-actionable
    /// telemetry — cmux must not double-prompt — but the hook bridge must
    /// raise the "Agent Needs Permission"-gated notification, or the blocked
    /// agent is silent indefinitely.
    /// https://github.com/manaflow-ai/cmux/issues/9592
    let notifiesNativeApprovalPrompt: Bool
    /// A tool COMPLETED for an agent whose approval prompts notify via
    /// ``notifiesNativeApprovalPrompt`` — execution strictly follows any
    /// approval, so the prompt resolved (approved by the user or by the
    /// agent's own auto-reviewer) and the bridge clears the pane's stale
    /// notifications. Only tool COMPLETION qualifies: pre-tool events fire
    /// when the agent intends to run a tool, with no ordering guarantee
    /// against the approval-prompt hook, so clearing there could erase a
    /// just-raised prompt while the agent is still blocked.
    ///
    /// The clear is deliberately pane-wide and uncorrelated with any single
    /// request: notifications carry no request identity anywhere in cmux,
    /// and every agent integration clears the same way on progress signals —
    /// Claude's `session-start`/`prompt-submit`/`pre-tool-use` hooks, the
    /// generic `.approvalResponse` action (Hermes' resolved native
    /// approvals), and codex's own `prompt-submit` hook (which also clears
    /// deny-without-further-tools residue at the next turn). Pane
    /// notifications are attention signals; agent progress in the pane makes
    /// them stale as a set.
    let clearsNativeApprovalPrompt: Bool
}

struct FeedEventClassifier {
    /// Classifies a raw agent hook event into our wire `hook_event_name`
    /// plus an `isActionable` flag that drives whether the Feed bridge
    /// blocks waiting for a user decision (and whether `FeedCoordinator`
    /// posts a "needs approval" notification), plus whether the bridge
    /// itself must raise the permission-prompt notification for an agent
    /// that blocks in its own native approval UI.
    ///
    /// - Parameters:
    ///   - source: The agent id that emitted the event (`claude`, `codex`,
    ///     `hermes-agent`, …). Unregistered sources are telemetry-only.
    ///   - event: The agent's raw hook event name.
    ///   - toolName: The tool the event refers to, used only for the two
    ///     tool-dependent semantics.
    static func classify(
        source: String,
        event: String,
        toolName: String
    ) -> FeedEventClassification {
        let semantic = feedEventSemantic(source: source, event: event)
        return wireMapping(for: semantic, source: source, toolName: toolName)
    }

    /// Whether any of `source`'s registered events carry the
    /// ``FeedEventSemantic/nativeApprovalPrompt`` semantic.
    private static func sourceRaisesNativeApprovalPrompts(_ source: String) -> Bool {
        feedEventSemanticRegistry[source]?.values.contains(.nativeApprovalPrompt) == true
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
        /// The agent is blocked waiting for the user in its OWN approval
        /// UI (e.g. Codex's approval reviewer). The feed event stays
        /// non-actionable telemetry — an actionable cmux Feed card would
        /// compete with the agent's native prompt and bypass features like
        /// Codex's "Approve for me" — but the bridge raises the
        /// "Agent Needs Permission"-gated notification so the blocked
        /// agent is not silent (#9592).
        case nativeApprovalPrompt
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

    /// Resolves the semantic for a `(source, event)` pair. Only registered
    /// sources can opt in to blocking decisions. Unregistered sources retain
    /// useful lifecycle names but always use telemetry-only semantics.
    private static func feedEventSemantic(
        source: String,
        event: String
    ) -> FeedEventSemantic {
        let table = feedEventSemanticRegistry[source] ?? telemetryOnlyFeedEventSemantics
        return table[event] ?? .unknown
    }

    /// Tool names that carry their own dedicated approval wire event rather
    /// than the generic `PermissionRequest`. Returns the actionable wire
    /// event name for such a tool, or `nil` for ordinary tools.
    private static func dedicatedApprovalEvent(for toolName: String) -> String? {
        switch toolName {
        case "ExitPlanMode": return "ExitPlanMode"
        case "AskUserQuestion": return "AskUserQuestion"
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
    ) -> FeedEventClassification {
        switch semantic {
        case .approvalRequest:
            return actionable(dedicatedApprovalEvent(for: toolName) ?? "PermissionRequest")
        case .toolStartMaybeApproval:
            if let dedicated = dedicatedApprovalEvent(for: toolName) {
                return actionable(dedicated)
            }
            // Any tool that can mutate the environment surfaces as a
            // permission request so the user can approve/deny from the
            // Feed sidebar. Read-only tools stay non-actionable
            // telemetry so we don't flood the Actionable view.
            if Self.isSideEffectingTool(toolName, source: source) {
                return actionable("PermissionRequest")
            }
            return telemetry("PreToolUse")
        case .toolStart:
            // Never clears the native approval prompt: agents fire their
            // pre-tool hooks when they INTEND to run a tool, with no ordering
            // guarantee against the approval-prompt hook, so a start-time
            // clear could erase a just-raised prompt while the agent is still
            // blocked — reintroducing the silence behind #9592.
            return telemetry("PreToolUse")
        case .nativeApprovalPrompt:
            // Same telemetry wire mapping as .toolStart (no blocking, no
            // actionable card), plus the permission-prompt notification.
            return FeedEventClassification(
                hookEventName: "PreToolUse",
                isActionable: false,
                notifiesNativeApprovalPrompt: true,
                clearsNativeApprovalPrompt: false
            )
        case .toolEnd:
            // A completed tool ran, and execution strictly follows any
            // approval — so this is the earliest progress signal that can
            // safely clear a resolved native approval prompt (approved by
            // the user or by the agent's own auto-reviewer). Scoped to
            // sources that raise those prompts so other agents' tool
            // telemetry never touches the notification queue.
            return FeedEventClassification(
                hookEventName: "PostToolUse",
                isActionable: false,
                notifiesNativeApprovalPrompt: false,
                clearsNativeApprovalPrompt: sourceRaisesNativeApprovalPrompts(source)
            )
        case .preCompact:
            return telemetry("PreCompact")
        case .postCompact:
            return telemetry("PostCompact")
        case .promptSubmit:
            return telemetry("UserPromptSubmit")
        case .subagentStart:
            return telemetry("SubagentStart")
        case .response:
            return telemetry("Stop")
        case .subagentResponse:
            return telemetry("SubagentStop")
        case .sessionStart:
            return telemetry("SessionStart")
        case .sessionEnd:
            return telemetry("SessionEnd")
        case .statusNotification:
            return telemetry("Notification")
        case .unknown:
            // Safe default: telemetry, no approval, no notification.
            return telemetry("PreToolUse")
        }
    }

    private static func actionable(_ hookEventName: String) -> FeedEventClassification {
        FeedEventClassification(
            hookEventName: hookEventName,
            isActionable: true,
            notifiesNativeApprovalPrompt: false,
            clearsNativeApprovalPrompt: false
        )
    }

    private static func telemetry(_ hookEventName: String) -> FeedEventClassification {
        FeedEventClassification(
            hookEventName: hookEventName,
            isActionable: false,
            notifiesNativeApprovalPrompt: false,
            clearsNativeApprovalPrompt: false
        )
    }

    /// Per-agent event-semantic tables. Each entry is the source of truth
    /// for that agent's `(event) -> semantic` mapping; events absent here
    /// resolve to ``FeedEventSemantic/unknown``.
    ///
    /// Blocking is an explicit capability: a source must be registered with
    /// ``FeedEventSemantic/toolStartMaybeApproval`` or
    /// ``FeedEventSemantic/approvalRequest``. New and incompatible sources
    /// fail neutral instead of inheriting a synchronous approval wait.
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
            // reviewer. Keep the feed side telemetry so "Approve for me" can
            // still use Codex's auto-review path instead of blocking on cmux
            // Feed, but raise the permission-prompt notification: this is the
            // only hook Codex fires while blocked on the user (#9592).
            "PermissionRequest": .nativeApprovalPrompt,
            "permission_request": .nativeApprovalPrompt,
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
        // Gemini CLI consumes the generic PreToolUse decision schema and has
        // no separate approval event, so it deliberately opts in to blocking.
        "gemini": approvalCapableFeedEventSemantics,
        // Kiro emits camelCase hook events and has no dedicated approval
        // event, so its pre-tool event escalates side-effecting tools to an
        // approval (resolved against the kiro tool aliases in
        // ``isSideEffectingTool``). Registering kiro explicitly is required:
        // its lowercase event names are absent from the shared tables.
        "kiro": [
            "preToolUse": .toolStartMaybeApproval,
            "postToolUse": .toolEnd,
            "userPromptSubmit": .promptSubmit,
            "agentSpawn": .sessionStart,
            "stop": .response,
        ],
        // Vibe has its own approval UI (tool permissions handled in the TUI),
        // so feed events are telemetry only — no blocking approval wait.
        "vibe": [
            "pre_tool": .toolStart,
            "post_tool": .toolEnd,
        ],
    ]

    /// Shared event spellings for sources that have a verified blocking
    /// decision contract. Registration is required; this table is never the
    /// fallback for an unknown source.
    private static let approvalCapableFeedEventSemantics: [String: FeedEventSemantic] = [
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

    /// Safe fallback for unregistered sources. Familiar event names preserve
    /// Feed telemetry classification, but none can create a blocking request.
    private static let telemetryOnlyFeedEventSemantics: [String: FeedEventSemantic] = [
        "PreToolUse": .toolStart,
        "beforeShellExecution": .toolStart,
        "PermissionRequest": .toolStart,
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

    /// Builds the pane-attention V1 socket command a classified feed event
    /// carries — the `needs-permission`-gated `notify_target_async` for a
    /// native approval prompt, or the pane-scoped `clear_notifications` for
    /// a resolved one. Pure so the exact wire command (UUID gating, payload
    /// shape, gate meta) is unit-testable; the CLI feed hook sends the
    /// returned line request/response and awaits the app's acknowledgement.
    ///
    /// Returns `nil` when the classification carries no attention side
    /// effect or when either identity is missing/not a UUID: the command is
    /// advisory and must never fail the hook.
    ///
    /// The notification body deliberately names only the TOOL — mirroring
    /// the in-app Feed approval banner (`feed.notification.permission.body`)
    /// — and never the tool input: commands can embed credentials, and
    /// notification banners reach lock screens, paired phones, and the
    /// recorded notification history.
    static func nativeApprovalPromptAttentionCommand(
        classification: FeedEventClassification,
        displayName: String,
        toolName: String,
        workspaceId: String?,
        surfaceId: String?
    ) -> String? {
        guard classification.notifiesNativeApprovalPrompt
                || classification.clearsNativeApprovalPrompt else { return nil }
        guard let workspaceRaw = workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              let workspaceUUID = UUID(uuidString: workspaceRaw),
              let surfaceRaw = surfaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              let surfaceUUID = UUID(uuidString: surfaceRaw)
        else { return nil }
        if classification.clearsNativeApprovalPrompt {
            return "clear_notifications --tab=\(workspaceUUID.uuidString) --panel=\(surfaceUUID.uuidString)"
        }
        let subtitle = String(
            localized: "agent.generic.notification.subtitle.permission",
            defaultValue: "Permission"
        )
        let sanitizedToolName = attentionNotificationField(toolName)
        let body: String
        if sanitizedToolName.isEmpty {
            body = String(
                localized: "agent.generic.notification.body.approvalNeeded",
                defaultValue: "Approval needed"
            )
        } else {
            body = String(
                localized: "feed.notification.permission.body",
                defaultValue: "\(sanitizedToolName) needs approval"
            )
        }
        guard let meta = AgentHookNotifyCategory.needsPermission.metaSegment(pending: false) else {
            return nil
        }
        let payload = [attentionNotificationField(displayName), attentionNotificationField(subtitle), attentionNotificationField(body)]
            .joined(separator: "|") + "|" + meta
        return "notify_target_async \(workspaceUUID.uuidString) \(surfaceUUID.uuidString) \(payload)"
    }

    /// Notification payload fields are pipe-delimited single lines; agent
    /// tool names are payload-controlled input, so normalize them the same
    /// way `notificationPayload` sanitizes its fields.
    private static func attentionNotificationField(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "|", with: "¦")
    }

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
