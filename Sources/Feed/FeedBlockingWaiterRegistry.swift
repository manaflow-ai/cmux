import CMUXAgentLaunch
import Foundation

/// Actor-owned request/reply state for blocking Feed socket calls.
///
/// Each request receives one buffered decision stream. Delivery is
/// first-writer-wins. Timeout finalization retains a short-lived sentinel until
/// the corresponding store item is expired, closing the reply/timeout race.
actor FeedBlockingWaiterRegistry {
    private var waiters: [String: FeedPendingWaiter] = [:]
    private var timedOutRequestIDs: Set<String> = []

    enum Completion {
        case resolved(FeedPendingWaiter, WorkstreamDecision)
        case timedOut(FeedPendingWaiter)
        case missing
    }

    func register(requestID: String) -> AsyncStream<WorkstreamDecision>? {
        guard waiters[requestID] == nil else { return nil }
        timedOutRequestIDs.remove(requestID)
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
        timedOut: Bool,
        itemID: UUID?,
        attentionTarget: FeedCoordinator.AttentionTarget?
    ) {
        guard var waiter = waiters[requestID] else {
            return (false, false, false, nil, nil)
        }
        if timedOutRequestIDs.contains(requestID) {
            return (false, true, true, waiter.itemID, waiter.attentionTarget)
        }
        guard waiter.decision == nil else {
            return (false, true, false, waiter.itemID, waiter.attentionTarget)
        }
        waiter.decision = decision
        waiters[requestID] = waiter
        waiter.continuation.yield(decision)
        waiter.continuation.finish()
        return (true, true, false, waiter.itemID, waiter.attentionTarget)
    }

    /// Atomically chooses the terminal state after the decision/timeout race.
    /// A decision already accepted by the actor wins; otherwise the waiter is
    /// retained as timed out until its store item finishes expiring, so a late
    /// reply cannot reopen the decision during that main-actor transition.
    func completeAfterWait(requestID: String) -> Completion {
        guard let waiter = waiters[requestID] else {
            return .missing
        }
        waiter.continuation.finish()
        if let decision = waiter.decision {
            waiters.removeValue(forKey: requestID)
            return .resolved(waiter, decision)
        }
        timedOutRequestIDs.insert(requestID)
        return .timedOut(waiter)
    }

    func expire(requestID: String) -> FeedPendingWaiter? {
        let waiter = waiters[requestID]
        waiter?.continuation.finish()
        if waiter != nil {
            timedOutRequestIDs.insert(requestID)
        }
        return waiter
    }

    func finalizeExpiration(requestID: String) {
        waiters.removeValue(forKey: requestID)
        timedOutRequestIDs.remove(requestID)
    }

    func remove(requestID: String) -> FeedPendingWaiter? {
        timedOutRequestIDs.remove(requestID)
        let waiter = waiters.removeValue(forKey: requestID)
        waiter?.continuation.finish()
        return waiter
    }

    func isAwaitingDecision(requestID: String) -> Bool {
        guard !timedOutRequestIDs.contains(requestID),
              let waiter = waiters[requestID] else { return false }
        return waiter.decision == nil
    }
}
