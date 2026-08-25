import Foundation

/// Bounds concurrent reference-plumbing snapshots across one service graph.
actor GitReferenceSnapshotLimiter {
    private let limit: Int
    private var activeCount = 0
    private var waiters: [GitReferenceSnapshotLimiterWaiter] = []

    init(limit: Int = 4) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
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
                    waiters.append(GitReferenceSnapshotLimiterWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: true)
            return
        }
        activeCount = max(0, activeCount - 1)
    }

    private func cancel(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        }
    }
}
