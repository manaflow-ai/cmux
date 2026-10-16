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
