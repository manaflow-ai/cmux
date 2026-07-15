import Foundation
import CMUXAgentLaunch
import os

/// Owns the synchronous request/reply bridge required by the control socket.
///
/// The socket handler is synchronous and must return the eventual agent
/// decision on the same worker thread. The semaphore parks only that worker;
/// the unfair lock protects short compare-and-update operations and never
/// guards ongoing Feed domain state.
final class FeedBlockingWaiterRegistry: @unchecked Sendable {
    struct PendingWaiter {
        let semaphore: DispatchSemaphore
        var decision: WorkstreamDecision?
        var attentionTarget: FeedCoordinator.AttentionTarget?
    }

    // Safety: every waiter-table access is serialized by this lock and every
    // critical section is bounded to an in-memory dictionary mutation.
    private let lock = OSAllocatedUnfairLock(initialState: [String: PendingWaiter]())

    func register(requestID: String) -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        lock.withLock { waiters in
            waiters[requestID] = PendingWaiter(semaphore: semaphore)
        }
        return semaphore
    }

    func setAttentionTarget(_ target: FeedCoordinator.AttentionTarget, requestID: String) {
        lock.withLock { waiters in
            waiters[requestID]?.attentionTarget = target
        }
    }

    func deliver(_ decision: WorkstreamDecision, requestID: String) -> FeedCoordinator.AttentionTarget? {
        let delivery = lock.withLock { waiters -> (DispatchSemaphore, FeedCoordinator.AttentionTarget?)? in
            guard var waiter = waiters[requestID] else { return nil }
            waiter.decision = decision
            waiters[requestID] = waiter
            return (waiter.semaphore, waiter.attentionTarget)
        }
        delivery?.0.signal()
        return delivery?.1
    }

    func remove(requestID: String) -> PendingWaiter? {
        lock.withLock { waiters in
            waiters.removeValue(forKey: requestID)
        }
    }

    func isAwaitingDecision(requestID: String) -> Bool {
        lock.withLock { waiters in
            waiters[requestID]?.decision == nil
        }
    }
}
