import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Foundation

/// A FIFO async semaphore: at most `limit` holders, and at most
/// `maximumWaiters` queued behind them (further acquirers fail at once, so
/// a flood of connections cannot queue unbounded).
public actor TunnelConcurrencyLimit {
    public let limit: Int
    public let maximumWaiters: Int
    private var holders = 0
    private var waiters: [(id: UUID, continuation: OnceContinuation<Bool, OnceContinuationError>)] = []

    public init(limit: Int, maximumWaiters: Int = 256) {
        self.limit = limit
        self.maximumWaiters = maximumWaiters
    }

    public var holderCount: Int { holders }
    public var waiterCount: Int { waiters.count }

    /// Waits for a slot. Returns false when the queue is full or the waiting
    /// task was cancelled.
    public func acquire() async -> Bool {
        if holders < limit {
            holders += 1
            return true
        }
        guard waiters.count < maximumWaiters, !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            // A dropped waiter holds no slot: false, as a cancelled one answers.
            (try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
                waiters.append((id, continuation))
            }) ?? false
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    public func release() {
        guard let next = waiters.first else {
            holders = max(0, holders - 1)
            return
        }
        // Hand the slot straight to the next waiter.
        waiters.removeFirst()
        next.continuation.resume(returning: true)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
