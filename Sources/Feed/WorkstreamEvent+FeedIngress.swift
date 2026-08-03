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
        case .preToolUse where toolName.map(isWorkstreamTaskTool) == true:
            // Task-tool calls are deltas: a dropped TaskCreate leaves the
            // accumulated checklist permanently wrong, so it cannot be
            // reconstructed from later traffic.
            return .sessionCritical
        case .postToolUse where toolName == "TaskCreate":
            // Carries the authoritative task id for a row created at
            // PreToolUse; dropping it strands that row on a provisional id.
            return .sessionCritical
        case .preToolUse, .postToolUse, .todoWrite,
             .subagentStart, .subagentStop, .preCompact, .postCompact:
            // Tool traffic is best-effort; prompt submission establishes working
            // state, while compaction/subagent events preserve the parent state.
            return .ordinary
        }
    }
}
