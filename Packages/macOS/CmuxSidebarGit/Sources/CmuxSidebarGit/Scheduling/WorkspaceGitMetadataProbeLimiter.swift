public import Foundation

/// Caps how many sidebar git metadata snapshot probes run concurrently
/// across the whole process.
///
/// Probes spawn `git` subprocesses; without a cap a burst of workspace
/// restores would fork dozens at once. The composition root constructs one
/// limiter and injects it into every window's ``SidebarGitMetadataService``
/// so the cap stays process-wide (the legacy code reached the same instance
/// through a `shared` singleton; injection replaces the singleton).
///
/// An `actor` because acquirers are detached background probe tasks
/// contending from arbitrary executors; the waiter queue is the contended
/// state and has no main-actor callers.
public actor WorkspaceGitMetadataProbeLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []
    private var cancelledWaiterIds: Set<UUID> = []

    /// Creates a limiter allowing at most `limit` concurrent probes
    /// (clamped to at least 1).
    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Waits for a probe permit. Returns `false` (without acquiring) when the
    /// calling task is cancelled before a permit frees up.
    public func acquire() async -> Bool {
        let id = UUID()
        guard !Task.isCancelled else { return false }
        if activeCount < limit {
            activeCount += 1
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledWaiterIds.remove(id) != nil {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }
    }

    /// Returns a permit, waking the oldest non-cancelled waiter if any.
    public func release() {
        guard activeCount > 0 else { return }
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if cancelledWaiterIds.remove(waiter.id) != nil {
                waiter.continuation.resume(returning: false)
                continue
            }
            waiter.continuation.resume(returning: true)
            return
        }
        activeCount -= 1
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        } else {
            cancelledWaiterIds.insert(id)
        }
    }
}
