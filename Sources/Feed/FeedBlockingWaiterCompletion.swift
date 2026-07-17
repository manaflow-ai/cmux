import CMUXAgentLaunch

enum FeedBlockingWaiterCompletion {
    case resolved(FeedPendingWaiter, WorkstreamDecision)
    case timedOut(FeedPendingWaiter)
    case missing
}
