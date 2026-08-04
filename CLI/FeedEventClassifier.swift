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
/// tool-starting lifecycle event becomes actionable only through an explicit
/// integration policy and the evidence that policy requires. Unknown / future
/// event names default to non-actionable telemetry that never notifies.
/// Conflating a generic tool-start with an approval is the bug behind
/// https://github.com/manaflow-ai/cmux/issues/4985.
struct FeedEventClassifier {
    /// Classifies a raw agent hook event into our wire `hook_event_name`
    /// plus an `isActionable` flag that drives whether the Feed bridge
    /// blocks waiting for a user decision (and whether `FeedCoordinator`
    /// posts a "needs approval" notification).
    ///
    /// - Parameters:
    ///   - source: The agent id that emitted the event (`claude`, `codex`,
    ///     `hermes-agent`, …). Unregistered sources are telemetry-only.
    ///   - event: The agent's raw hook event name.
    ///   - toolName: The tool the event refers to, used only by
    ///     integration-specific approval semantics.
    /// - Returns: The wire `hook_event_name` and whether the event is
    ///   Feed-actionable (blocks + may notify).
    static func classify(
        source: String,
        event: String,
        toolName: String
    ) -> (String, Bool) {
        let semantic = feedEventSemantic(source: source, event: event)
        return wireMapping(
            for: semantic,
            source: source,
            toolName: toolName
        )
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

    /// Resolves the semantic for a `(source, event)` pair. Every built-in
    /// integration has an entry in the exhaustive registry, so a newly added
    /// built-in cannot silently lose approval handling. Truly unknown
    /// third-party sources retain telemetry-only fallback behavior.
    private static func feedEventSemantic(
        source: String,
        event: String
    ) -> FeedEventSemantic {
        guard let integration = BuiltInAgentIntegration(feedSourceName: source),
              let table = feedEventSemanticRegistry[integration] else {
            return telemetryOnlyFeedEventSemantics[event] ?? .unknown
        }
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

    /// Exhaustive built-in registry. Its keys are generated from
    /// ``BuiltInAgentIntegration/allCases`` and each value comes from an
    /// exhaustive switch, replacing the previous opt-in dictionary.
    private static let feedEventSemanticRegistry: [
        BuiltInAgentIntegration: [String: FeedEventSemantic]
    ] = Dictionary(uniqueKeysWithValues: BuiltInAgentIntegration.allCases.map {
        ($0, feedEventSemantics(for: $0))
    })

    private static func feedEventSemantics(
        for integration: BuiltInAgentIntegration
    ) -> [String: FeedEventSemantic] {
        var semantics = builtInFeedEventSemantics(
            approvalDetection: integration.approvalDetectionMechanism
        )
        switch integration {
        case .codex:
            semantics.merge([
                "permission_request": .approvalRequest,
                "pre_tool_use": .toolStart,
                "beforeShellExecution": .toolStart,
                "post_tool_use": .toolEnd,
                "pre_compact": .preCompact,
                "post_compact": .postCompact,
                "user_prompt_submit": .promptSubmit,
                "session_start": .sessionStart,
                "session_end": .sessionEnd,
                "stop": .response,
                "subagent_start": .subagentStart,
                "subagent_stop": .subagentResponse,
                "notification": .statusNotification,
            ], uniquingKeysWith: { _, replacement in replacement })
        case .hermesAgent:
            semantics.merge([
                // Hermes has a separate approval signal, so tool starts stay
                // telemetry and its dedicated notification lane owns the
                // visible approval banner (#4985).
                "pre_tool_call": .toolStart,
                "post_tool_call": .toolEnd,
                "pre_approval_request": .statusNotification,
                "post_approval_response": .statusNotification,
                "pre_llm_call": .promptSubmit,
                "post_llm_call": .response,
                "on_session_start": .sessionStart,
                "on_session_reset": .sessionStart,
                "on_session_end": .sessionEnd,
                "on_session_finalize": .sessionEnd,
            ], uniquingKeysWith: { _, replacement in replacement })
        case .kiro:
            semantics.merge([
                "preToolUse": .toolStartMaybeApproval,
                "postToolUse": .toolEnd,
                "userPromptSubmit": .promptSubmit,
                "agentSpawn": .sessionStart,
                "stop": .response,
            ], uniquingKeysWith: { _, replacement in replacement })
        case .amp, .antigravity, .campfire, .claude, .codebuddy, .copilot,
             .cursor, .factory, .gemini, .grok, .kimi, .omp, .opencode, .pi,
             .qoder, .rovodev:
            break
        }
        return semantics
    }

    /// Shared event spellings every built-in must support. A dedicated
    /// `PermissionRequest` is always actionable. Raw tool-start behavior is
    /// explicitly selected by the integration's required approval mechanism.
    private static func builtInFeedEventSemantics(
        approvalDetection: AgentApprovalDetectionMechanism
    ) -> [String: FeedEventSemantic] {
        let semantics: (
            toolStart: FeedEventSemantic,
            shellStart: FeedEventSemantic
        ) = switch approvalDetection {
        case .dedicatedPermissionEvent:
            (.toolStart, .toolStart)
        case .sideEffectingToolStartInference:
            (.toolStartMaybeApproval, .toolStartMaybeApproval)
        case .nativePostPolicyObserver:
            (.toolStart, .toolStart)
        }
        return [
            "PreToolUse": semantics.toolStart,
            "preToolUse": semantics.toolStart,
            "beforeShellExecution": semantics.shellStart,
            "PermissionRequest": .approvalRequest,
            "permissionRequest": .approvalRequest,
            "permission_request": .approvalRequest,
            "PostToolUse": .toolEnd,
            "postToolUse": .toolEnd,
            "postToolUseFailure": .toolEnd,
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
    }

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

enum AgentNativeApprovalLogDecision: Equatable, Sendable {
    case approvalRequested(toolCallId: String?)
    case autoApproved(toolCallId: String?)
}

/// Pure classifier for Cursor's post-hook native shell-policy records.
///
/// Cursor's pre-policy hooks cannot truthfully say whether a prompt will be
/// shown. Its own structured debug stream records exactly one of these
/// decisions after `preToolUse` returns and includes the same tool-call id.
/// Only the matching native "requesting" record may surface Needs Input.
struct CursorNativeApprovalLogClassifier {
    private static let requestingMarker =
        "Shell permissions: requesting shell approval"
    private static let autoApprovedMarker =
        "Shell permissions: auto-approved shell command"

    static func classify(
        line: String,
        expectedToolCallId: String? = nil
    ) -> AgentNativeApprovalLogDecision? {
        let isApprovalRequest: Bool
        let toolCallId: String?
        if let dictionary = decodedObject(in: line) {
            let message = ["msg", "message"].compactMap {
                dictionary[$0] as? String
            }.first
            if message == requestingMarker {
                isApprovalRequest = true
            } else if message == autoApprovedMarker {
                isApprovalRequest = false
            } else {
                return nil
            }
            toolCallId = dictionary["toolCallId"] as? String
        } else {
            if containsPrefixedDecisionMessage(
                requestingMarker,
                in: line
            ) {
                isApprovalRequest = true
            } else if containsPrefixedDecisionMessage(
                autoApprovedMarker,
                in: line
            ) {
                isApprovalRequest = false
            } else {
                return nil
            }
            toolCallId = jsonStringField("toolCallId", in: line)
        }

        guard let toolCallId, !toolCallId.isEmpty else {
            return nil
        }
        if let expectedToolCallId,
           toolCallId != expectedToolCallId {
            return nil
        }
        return isApprovalRequest
            ? .approvalRequested(toolCallId: toolCallId)
            : .autoApproved(toolCallId: toolCallId)
    }

    private static func decodedObject(
        in line: String
    ) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func containsPrefixedDecisionMessage(
        _ expected: String,
        in line: String
    ) -> Bool {
        // Older Cursor logger configurations prefix a human-readable timestamp
        // and append the structured fields as JSON. Require the decision text
        // to be the message immediately before that object, rather than merely
        // appearing somewhere in a user-controlled command string.
        guard let range = line.range(of: expected) else { return false }
        return line[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("{")
    }

    private static func jsonStringField(
        _ key: String,
        in line: String
    ) -> String? {
        let marker = "\"\(key)\""
        guard let keyRange = line.range(of: marker) else { return nil }
        var cursor = keyRange.upperBound
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex, line[cursor] == ":" else { return nil }
        cursor = line.index(after: cursor)
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex, line[cursor] == "\"" else { return nil }
        cursor = line.index(after: cursor)

        var value = ""
        var escaped = false
        while cursor < line.endIndex {
            let character = line[cursor]
            cursor = line.index(after: cursor)
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return value.isEmpty ? nil : value
            } else {
                value.append(character)
            }
        }
        return nil
    }
}
