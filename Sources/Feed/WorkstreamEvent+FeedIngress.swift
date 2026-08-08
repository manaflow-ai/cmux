import CMUXAgentLaunch

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
        case .todoWrite:
            // An authoritative whole-list snapshot. Dropping the final clear
            // or completion under queue pressure leaves checklist rows stale
            // with nothing later to correct them.
            return .sessionCritical
        case .postToolUse where toolName.map(isWorkstreamTaskTool) == true:
            // Task-tool results are deltas carrying the authoritative task id:
            // a dropped one leaves the accumulated checklist permanently
            // wrong, and it cannot be reconstructed from later traffic.
            return .sessionCritical
        case .preToolUse, .postToolUse,
             .subagentStart, .subagentStop, .preCompact, .postCompact:
            // Tool traffic is best-effort; prompt submission establishes working
            // state, while compaction/subagent events preserve the parent state.
            return .ordinary
        }
    }
}
