import Foundation

extension TerminalSurface {
    /// Starts this surface's runtime for input demand and waits until it is live.
    ///
    /// The runtime lifecycle owns the answer: creation success, creation failure,
    /// close and agent hibernation settle every waiter synchronously on the
    /// surface's isolation. `timeout` only bounds this caller's wait and never
    /// decides that the runtime is ready.
    ///
    /// - Parameter timeout: Maximum time this caller waits for the lifecycle.
    /// - Returns: `true` when the runtime is live, otherwise `false`.
    @MainActor
    public func waitForRuntimeSurfaceReady(timeout: Duration = .seconds(2)) async -> Bool {
        guard !Task.isCancelled else { return false }
        if liveSurfaceForGhosttyAccess(reason: "runtime.ready") != nil { return true }
        guard runtimeUnavailableReason == .awaitingRestore || canCreateRuntimeSurface else {
            return false
        }
        // The start is queued on the main actor, so it cannot settle before
        // this waiter registers below without an intervening suspension.
        requestInputDemandSurfaceStartIfNeeded()

        let waiterID = UUID()
        let clock = runtimeReadinessClock
        // The caller's budget, owned by this call: it settles the waiter when
        // the budget runs out or the caller is cancelled, and is cancelled on
        // return once the lifecycle has answered.
        let budget = Task { @MainActor [weak self] in
            try? await clock.sleep(for: timeout, tolerance: nil)
            self?.settleRuntimeReadinessWaiter(waiterID, ready: false)
        }
        defer { budget.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    runtimeReadinessWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            budget.cancel()
        }
    }

    /// Settles every runtime-readiness waiter with a lifecycle outcome.
    ///
    /// Called on the surface's isolation when runtime creation succeeds or
    /// fails, and when the surface closes or suspends for agent hibernation.
    func completeRuntimeReadiness(success: Bool) {
        guard !runtimeReadinessWaiters.isEmpty else { return }
        let waiters = runtimeReadinessWaiters.values
        runtimeReadinessWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: success)
        }
    }

    private func settleRuntimeReadinessWaiter(_ waiterID: UUID, ready: Bool) {
        runtimeReadinessWaiters.removeValue(forKey: waiterID)?.resume(returning: ready)
    }
}
