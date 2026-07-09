import Foundation

/// Thread-safe table of in-flight blocking-decision waiters keyed by request
/// id. The socket worker registers a waiter, parks on the returned semaphore,
/// and the `feed.*.reply` path delivers the decision (waking the worker) from
/// another thread.
///
/// Guarded by an `NSLock` rather than an actor because every caller is
/// synchronous, non-`async` code that also blocks on the semaphore: the worker
/// registers and then calls `semaphore.wait`, and the ingest hop sets the
/// attention target from inside a `DispatchQueue.main.sync`. Moving the table
/// onto an actor would require those call sites to suspend, which is a behavior
/// rewrite, so this stays a small lock-guarded registry.
public final class BlockingDecisionWaiterRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [String: BlockingDecisionWaiter] = [:]

    public init() {}

    /// Registers a fresh waiter for `requestId` and returns the semaphore the
    /// caller should block on until the decision resolves or times out. The
    /// waiter is recorded before the caller surfaces the event so a very fast
    /// reply cannot slip through.
    public func register(requestId: String) -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        let waiter = BlockingDecisionWaiter(semaphore: semaphore)
        lock.lock()
        waiters[requestId] = waiter
        lock.unlock()
        return semaphore
    }

    /// Records the attention overlay target for `requestId`'s waiter, if it is
    /// still registered.
    public func setAttentionTarget(_ target: AttentionTarget, requestId: String) {
        lock.lock()
        waiters[requestId]?.attentionTarget = target
        lock.unlock()
    }

    /// Removes and returns `requestId`'s waiter, if any. After removal the
    /// returned waiter is owned solely by the caller, so its slots can be read
    /// without the lock.
    public func removeWaiter(requestId: String) -> BlockingDecisionWaiter? {
        lock.lock()
        let waiter = waiters.removeValue(forKey: requestId)
        lock.unlock()
        return waiter
    }

    /// Delivers `decision` to `requestId`'s waiter: fills its decision slot and
    /// signals its semaphore so the parked worker wakes. Returns the attention
    /// overlay target recorded for the waiter (read under the lock before the
    /// signal), or `nil` if no waiter is registered.
    public func deliverDecision(_ decision: WorkstreamDecision, requestId: String) -> AttentionTarget? {
        lock.lock()
        let attentionTarget = waiters[requestId]?.attentionTarget
        if let waiter = waiters[requestId] {
            waiter.decision = decision
            waiter.semaphore.signal()
        }
        lock.unlock()
        return attentionTarget
    }

    /// Returns `true` while `requestId`'s waiter exists and has no decision yet.
    public func isAwaitingDecision(requestId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let waiter = waiters[requestId] else { return false }
        return waiter.decision == nil
    }
}
