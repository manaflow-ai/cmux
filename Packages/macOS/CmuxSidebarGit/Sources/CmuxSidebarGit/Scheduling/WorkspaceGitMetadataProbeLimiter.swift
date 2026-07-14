public import CmuxGit
public import Foundation

/// Owns independent process-wide concurrency limits for sidebar git probes and
/// pull-request refresh chains.
///
/// Probes spawn `git` subprocesses; without a cap a burst of workspace
/// restores would fork dozens at once. The composition root injects one scheduler
/// into every window, while separate permit pools keep longer GitHub refreshes
/// from blocking latency-sensitive local git metadata probes.
///
/// An `actor` because acquirers are detached background probe tasks
/// contending from arbitrary executors; the waiter queue is the contended
/// state and has no main-actor callers.
public actor WorkspaceGitMetadataProbeLimiter: PullRequestPanelRefreshLimiting {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private let pullRequestRefreshLimiter: PullRequestPanelRefreshLimiter
    private var activeCount = 0
    private var waiters: [Waiter] = []

    /// Creates a limiter allowing at most `limit` concurrent probes
    /// (clamped to at least 1).
    public init(limit: Int) {
        self.limit = max(1, limit)
        pullRequestRefreshLimiter = PullRequestPanelRefreshLimiter(limit: 2)
    }

    /// Waits for an independently capped pull-request refresh permit.
    public func acquirePullRequestRefresh() async -> Bool {
        await pullRequestRefreshLimiter.acquirePullRequestRefresh()
    }

    /// Returns a pull-request refresh permit without changing git-probe capacity.
    public func releasePullRequestRefresh() async {
        await pullRequestRefreshLimiter.releasePullRequestRefresh()
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
                if Task.isCancelled {
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
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume(returning: true)
            return
        }
        activeCount -= 1
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        }
    }
}
