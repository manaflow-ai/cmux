import Foundation

/// A cancellation-aware FIFO concurrency limit for pull-request refresh chains.
public actor PullRequestPanelRefreshLimiter: PullRequestPanelRefreshLimiting {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    /// Creates a limiter allowing at most `limit` active refresh chains.
    /// - Parameter limit: The concurrency cap, clamped to at least one.
    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Waits for a refresh permit, returning `false` if cancellation wins first.
    public func acquire() async -> Bool {
        let id = UUID()
        guard !Task.isCancelled else { return false }
        if activeCount < limit {
            activeCount += 1
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    /// Returns a permit to the oldest waiter that has not been cancelled.
    public func release() {
        guard activeCount > 0 else { return }
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume(returning: true)
            return
        }
        activeCount -= 1
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(returning: false)
        }
    }
}
