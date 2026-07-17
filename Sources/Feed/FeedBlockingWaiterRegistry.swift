import CMUXAgentLaunch
import Foundation

/// Actor-owned request/reply state for blocking Feed socket calls.
///
/// Each request receives one buffered decision stream. Delivery is
/// first-writer-wins, and timeout removal finishes the stream so no suspended
/// consumer or continuation outlives its socket request.
actor FeedBlockingWaiterRegistry {
    private var waiters: [String: FeedPendingWaiter] = [:]

    func register(requestID: String) -> AsyncStream<WorkstreamDecision>? {
        guard waiters[requestID] == nil else { return nil }
        let (stream, continuation) = AsyncStream<WorkstreamDecision>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        waiters[requestID] = FeedPendingWaiter(
            continuation: continuation,
            decision: nil,
            itemID: nil,
            attentionTarget: nil
        )
        return stream
    }

    /// Records the UI state created for a still-pending waiter. Returns false
    /// when the request resolved or timed out while MainActor was ingesting it.
    func recordIngest(
        itemID: UUID?,
        attentionTarget: FeedCoordinator.AttentionTarget?,
        requestID: String
    ) -> (registered: Bool, earlyDecision: WorkstreamDecision?) {
        guard var waiter = waiters[requestID] else {
            return (false, nil)
        }
        waiter.itemID = itemID
        waiter.attentionTarget = attentionTarget
        waiters[requestID] = waiter
        return (true, waiter.decision)
    }

    func deliver(
        _ decision: WorkstreamDecision,
        requestID: String
    ) -> (
        accepted: Bool,
        registered: Bool,
        itemID: UUID?,
        attentionTarget: FeedCoordinator.AttentionTarget?
    ) {
        guard var waiter = waiters[requestID] else {
            return (false, false, nil, nil)
        }
        guard waiter.decision == nil else {
            return (false, true, waiter.itemID, waiter.attentionTarget)
        }
        waiter.decision = decision
        waiters[requestID] = waiter
        waiter.continuation.yield(decision)
        waiter.continuation.finish()
        return (true, true, waiter.itemID, waiter.attentionTarget)
    }

    func remove(requestID: String) -> FeedPendingWaiter? {
        let waiter = waiters.removeValue(forKey: requestID)
        waiter?.continuation.finish()
        return waiter
    }

    func isAwaitingDecision(requestID: String) -> Bool {
        guard let waiter = waiters[requestID] else { return false }
        return waiter.decision == nil
    }
}
