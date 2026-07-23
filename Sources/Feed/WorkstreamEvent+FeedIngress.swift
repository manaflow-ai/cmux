import CMUXAgentLaunch

extension WorkstreamEvent {
    var feedIngressDeliveryKey: FeedIngressDeliveryLane.Key {
        FeedIngressDeliveryLane.Key(
            source: source,
            sessionId: sessionId
        )
    }

    var zeroWaitFeedIngressImportance: FeedIngressDeliveryLane.Importance {
        switch hookEventName {
        case .sessionStart, .sessionEnd, .userPromptSubmit, .stop,
             .subagentStart, .subagentStop, .preCompact, .postCompact,
             .permissionRequest, .askUserQuestion, .exitPlanMode:
            return .lifecycle
        case .preToolUse, .postToolUse, .todoWrite, .notification:
            return .ordinary
        }
    }
}
