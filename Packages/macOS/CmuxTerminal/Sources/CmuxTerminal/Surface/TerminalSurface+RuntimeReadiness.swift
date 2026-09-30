import Foundation

struct TerminalSurfaceRuntimeReadinessWaiter {
    let generation: UInt64
    let continuation: AsyncStream<Bool>.Continuation
}

extension TerminalSurface {
    /// Waits for this surface's lifecycle owner to finish the current runtime start.
    ///
    /// Runtime creation and teardown resolve the lifecycle-owned waiters. The
    /// optional timeout is only a budget for this caller; it never decides that
    /// the runtime is ready or replaces the lifecycle's completion signal.
    ///
    /// - Parameter timeout: Maximum caller wait, or `nil` to wait for lifecycle
    ///   completion or task cancellation.
    /// - Returns: `true` when the current runtime is live, otherwise `false`.
    @MainActor
    public func waitForRuntimeSurfaceReady(timeout: Duration? = .seconds(2)) async -> Bool {
        guard !Task.isCancelled else { return false }
        if liveSurfaceForGhosttyAccess(reason: "runtime.ready") != nil { return true }
        guard runtimeUnavailableReason == .awaitingRestore || canCreateRuntimeSurface else {
            return false
        }

        let waiterID = UUID()
        let waitTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.waitForRuntimeReadinessEvent(waiterID: waiterID)
        }

        return await withTaskCancellationHandler {
            if let timeout {
                return await withTaskGroup(of: Bool?.self) { group in
                    group.addTask { await waitTask.value }
                    let clock = runtimeReadinessClock
                    group.addTask {
                        do {
                            try await clock.sleep(for: timeout, tolerance: nil)
                            return false
                        } catch {
                            return nil
                        }
                    }
                    let result = await group.next() ?? nil
                    if result == false {
                        cancelRuntimeReadinessWaiter(waiterID)
                    }
                    waitTask.cancel()
                    group.cancelAll()
                    return result ?? false
                }
            }
            return await waitTask.value
        } onCancel: {
            waitTask.cancel()
        }
    }

    @MainActor
    private func waitForRuntimeReadinessEvent(waiterID: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        if liveSurfaceForGhosttyAccess(reason: "runtime.ready.register") != nil { return true }
        let (events, continuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        runtimeReadinessWaiters[waiterID] = TerminalSurfaceRuntimeReadinessWaiter(
            generation: runtimeSurfaceGeneration,
            continuation: continuation
        )

        // Register before requesting input-demand startup so a synchronous
        // headless create cannot complete before the waiter is visible.
        requestInputDemandSurfaceStartIfNeeded()
        if liveSurfaceForGhosttyAccess(reason: "runtime.ready.register") != nil {
            completeRuntimeReadiness(success: true)
        } else if !canCreateRuntimeSurface,
                  runtimeUnavailableReason != .awaitingRestore {
            completeRuntimeReadiness(success: false)
        }

        defer {
            runtimeReadinessWaiters.removeValue(forKey: waiterID)?.continuation.finish()
        }
        for await result in events {
            return result
        }
        return false
    }

    @MainActor
    private func cancelRuntimeReadinessWaiter(_ waiterID: UUID) {
        runtimeReadinessWaiters.removeValue(forKey: waiterID)?.continuation.finish()
    }

    /// Completes every waiter for this lifecycle state. Called only after the
    /// runtime has been registered and initialized, or when its owner closes.
    func completeRuntimeReadiness(success: Bool) {
        let waiters = runtimeReadinessWaiters
        var pending: [UUID: TerminalSurfaceRuntimeReadinessWaiter] = [:]
        for (waiterID, waiter) in waiters {
            if !success || waiter.generation < runtimeSurfaceGeneration {
                waiter.continuation.yield(success)
                waiter.continuation.finish()
            } else {
                pending[waiterID] = waiter
            }
        }
        runtimeReadinessWaiters = pending
    }
}
