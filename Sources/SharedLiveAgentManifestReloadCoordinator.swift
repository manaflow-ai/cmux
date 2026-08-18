import Foundation

/// Main-actor state that coalesces manifest invalidations with index scans.
@MainActor
final class SharedLiveAgentManifestReloadCoordinator {
    private(set) var revision: UInt64 = 0
    private(set) var directRefreshCount = 0
    private var reloadPending = false
    private var directRefreshWaiters: [CheckedContinuation<Void, Never>] = []

    var directRefreshIsInFlight: Bool { directRefreshCount > 0 }

    func invalidate(otherRefreshIsInFlight: Bool) {
        revision &+= 1
        if otherRefreshIsInFlight || directRefreshIsInFlight {
            reloadPending = true
        }
    }

    func beginDirectRefresh() {
        directRefreshCount += 1
    }

    /// Finishes one direct refresh and returns whether it was the last one.
    func endDirectRefresh() -> Bool {
        directRefreshCount -= 1
        return directRefreshCount == 0
    }

    func waitForDirectRefreshes() async {
        guard directRefreshIsInFlight else { return }
        await withCheckedContinuation { continuation in
            directRefreshWaiters.append(continuation)
        }
    }

    func resumeDirectRefreshWaiters() {
        let waiters = directRefreshWaiters
        directRefreshWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func takePendingReload(otherRefreshIsInFlight: Bool) -> Bool {
        guard reloadPending,
              !otherRefreshIsInFlight,
              !directRefreshIsInFlight else {
            return false
        }
        reloadPending = false
        return true
    }

    func scanIsCurrent(revision loadedRevision: UInt64) -> Bool {
        loadedRevision == revision
    }
}
