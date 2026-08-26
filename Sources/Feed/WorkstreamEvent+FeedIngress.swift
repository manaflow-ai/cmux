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
            // Whole-list snapshots must not be dropped: an empty snapshot is
            // the only signal that the agent cleared its final task.
            return .sessionCritical
        case .preToolUse, .postToolUse, .postToolUseFailure
            where event.toolName.flatMap(WorkstreamTaskTool.init(rawValue:)) != nil:
            // Task deltas cannot be reconstructed from later tool traffic.
            return .sessionCritical
        case .preToolUse, .postToolUse, .postToolUseFailure,
             .subagentStart, .subagentStop, .preCompact, .postCompact:
            // Tool traffic is best-effort; prompt submission establishes working
            // state, while compaction/subagent events preserve the parent state.
            return .ordinary
        }
    }
}
