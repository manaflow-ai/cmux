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
        case .preToolUse, .postToolUse, .todoWrite,
             .subagentStart, .subagentStop, .preCompact, .postCompact:
            // Tool traffic is best-effort; prompt submission establishes working
            // state, while compaction/subagent events preserve the parent state.
            return .ordinary
        }
    }
}
