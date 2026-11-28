import CMUXAgentLaunch
import Foundation

extension WorkstreamEvent {
    var feedIngressDeliveryKey: FeedIngressDeliveryKey {
        FeedIngressDeliveryKey(
            source: source,
            sessionId: sessionId
        )
    }

    var zeroWaitFeedIngressImportance: FeedIngressDeliveryImportance {
        switch hookEventName {
        case .sessionStart, .sessionEnd, .userPromptSubmit, .stop,
             .permissionRequest, .askUserQuestion, .exitPlanMode, .notification:
            // These establish authoritative session phase or needs-input state that cannot be
            // reconstructed from a later high-volume tool telemetry event.
            return .sessionCritical
        case .preToolUse, .postToolUse, .postToolUseFailure, .todoWrite,
             .subagentStart, .subagentStop, .preCompact, .postCompact:
            // Tool traffic is best-effort; prompt submission establishes working
            // state, while compaction/subagent events preserve the parent state.
            return .ordinary
        }
    }

    /// Wall-clock milliseconds at which the hook CLI sent this frame, on the
    /// agent host's clock. A blocking request is stamped only after its
    /// ordering barrier drained every hook the agent published before it.
    var feedHookSentAtMs: Int64? {
        guard let value = feedExtraFields?["_hook_sent_at_ms"] as? NSNumber,
              value.int64Value >= 0 else { return nil }
        return value.int64Value
    }

    /// The agent's subagent identity; `nil` for the main agent thread.
    var feedAgentID: String? {
        guard let value = feedExtraFields?["agent_id"] as? String,
              !value.isEmpty else { return nil }
        return value
    }

    /// The subagent type of the agent that fired the hook, when it named one.
    var feedAgentType: String? {
        guard let value = feedExtraFields?["agent_type"] as? String,
              !value.isEmpty else { return nil }
        return value
    }

    /// The agent's own id for the spawn tool call that opened a subagent.
    var feedSpawnToolUseID: String? {
        guard let value = feedExtraFields?["spawn_tool_use_id"] as? String,
              !value.isEmpty else { return nil }
        return value
    }

    /// Task and tool-use ids the prompt's `<task-notification>` blocks report
    /// as finished or stopped.
    var feedFinishedTaskIDs: [String] {
        feedExtraFields?["finished_task_ids"] as? [String] ?? []
    }

    /// True for the synchronous hook lane whose event order is established by
    /// the agent before the frame is sent. Detached telemetry workers omit this
    /// marker because their completion can arrive after a newer prompt.
    var feedHookIsOrdered: Bool {
        feedExtraFields?["_cmux_ordered_hook"] as? Bool == true
    }

    private var feedExtraFields: [String: Any]? {
        guard let data = extraFieldsJSON?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
