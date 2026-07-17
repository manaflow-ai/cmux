import CMUXAgentLaunch
import Foundation

struct FeedPendingWaiter {
    let continuation: AsyncStream<WorkstreamDecision>.Continuation
    var decision: WorkstreamDecision?
    var itemID: UUID?
    var attentionTarget: FeedCoordinator.AttentionTarget?
}
