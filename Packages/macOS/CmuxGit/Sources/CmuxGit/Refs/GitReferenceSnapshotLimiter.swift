import Dispatch
import Foundation

/// Bounds concurrent reference-plumbing snapshots across one service graph.
actor GitReferenceSnapshotLimiter {
    private static let maximumWaiterCount = 64
    private let limit: Int
    private var activeCount = 0
    private var waiters: [GitReferenceSnapshotLimiterWaiter] = []

    init(limit: Int = 4) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        await acquire(waitingUntil: nil)
    }

    /// Acquires a permit only when it is available before an aggregate deadline.
    ///
    /// Deadline-bound callers intentionally do not enqueue: waiting behind an
    /// older plumbing command would make a recursive watch exceed its caller's
    /// single wall-clock budget. They degrade to an unreadable snapshot instead.
    func acquire(until deadline: DispatchTime) async -> Bool {
        guard deadline > DispatchTime.now() else { return false }
        return await acquire(waitingUntil: deadline)
    }

    private func acquire(waitingUntil deadline: DispatchTime?) async -> Bool {
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
                } else if waiters.count >= Self.maximumWaiterCount {
                    continuation.resume(returning: false)
                } else {
                    let timeoutTask: Task<Void, Never>?
                    if let deadline {
                        let now = DispatchTime.now()
                        guard deadline > now else {
                            continuation.resume(returning: false)
                            return
                        }
                        let remainingNanoseconds = deadline.uptimeNanoseconds - now.uptimeNanoseconds
                        // This sleep is the caller's real aggregate deadline,
                        // not polling or state-settling synchronization.
                        timeoutTask = Task { [weak self] in
                            do {
                                try await Task<Never, Never>.sleep(
                                    for: .nanoseconds(Int64(remainingNanoseconds))
                                )
                            } catch {
                                return
                            }
                            guard !Task.isCancelled else { return }
                            await self?.expire(id: id)
                        }
                    } else {
                        timeoutTask = nil
                    }
                    waiters.append(GitReferenceSnapshotLimiterWaiter(
                        id: id,
                        continuation: continuation,
                        timeoutTask: timeoutTask
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: true)
            return
        }
        activeCount = max(0, activeCount - 1)
    }

    private func cancel(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: false)
        }
    }

    private func expire(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}
