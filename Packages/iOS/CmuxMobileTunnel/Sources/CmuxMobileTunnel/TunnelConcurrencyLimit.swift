import Foundation

/// A FIFO async semaphore: at most `limit` holders, and at most
/// `maximumWaiters` queued behind them (further acquirers fail at once, so
/// a flood of connections cannot queue unbounded).
public actor TunnelConcurrencyLimit {
    public let limit: Int
    public let maximumWaiters: Int
    private var holders = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

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
            await withCheckedContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    public func release() {
        if waiters.isEmpty {
            holders = max(0, holders - 1)
        } else {
            // Hand the slot straight to the next waiter.
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
