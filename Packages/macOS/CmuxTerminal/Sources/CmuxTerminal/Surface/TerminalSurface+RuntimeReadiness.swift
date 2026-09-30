import Foundation

struct TerminalSurfaceRuntimeReadinessWaiter: Sendable {
    let generation: UInt64
    let readinessEpoch: UInt64
    let continuation: AsyncStream<Bool>.Continuation
}

actor TerminalSurfaceRuntimeReadinessStore {
    private var waiters: [UUID: TerminalSurfaceRuntimeReadinessWaiter] = [:]
    private var lastCompletion: (epoch: UInt64, success: Bool, generation: UInt64?)?
    private var terminalFailure = false

    func begin() {
        terminalFailure = false
    }

    func register(
        _ waiterID: UUID,
        generation: UInt64,
        readinessEpoch: UInt64,
        continuation: AsyncStream<Bool>.Continuation
    ) {
        if terminalFailure {
            continuation.yield(false)
            continuation.finish()
            return
        }
        if let lastCompletion, lastCompletion.epoch >= readinessEpoch {
            continuation.yield(lastCompletion.success)
            continuation.finish()
            return
        }
        waiters[waiterID] = TerminalSurfaceRuntimeReadinessWaiter(
            generation: generation,
            readinessEpoch: readinessEpoch,
            continuation: continuation
        )
    }

    func cancel(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.continuation.finish()
    }

    func complete(_ waiterID: UUID, success: Bool) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.yield(success)
        waiter.continuation.finish()
    }

    func complete(
        success: Bool,
        readinessEpoch: UInt64?,
        currentGeneration: UInt64?
    ) {
        if readinessEpoch == nil {
            terminalFailure = !success
        }
        if let readinessEpoch {
            lastCompletion = (readinessEpoch, success, currentGeneration)
        }
        let pending = waiters
        waiters.removeAll(keepingCapacity: true)
        for (waiterID, waiter) in pending {
            let matchesEpoch: Bool
            if let readinessEpoch {
                matchesEpoch = waiter.readinessEpoch <= readinessEpoch
            } else {
                matchesEpoch = true
            }
            if matchesEpoch && (!success || waiter.generation < (currentGeneration ?? .max)) {
                waiter.continuation.yield(success)
                waiter.continuation.finish()
            } else {
                waiters[waiterID] = waiter
            }
        }
    }
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
                        await cancelRuntimeReadinessWaiter(waiterID)
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
        // Starting first advances the lifecycle epoch. The actor retains the
        // result if the native start wins the registration race; the live-state
        // check below covers a successful start before registration.
        requestInputDemandSurfaceStartIfNeeded()
        await runtimeReadinessStore.begin()
        await runtimeReadinessStore.register(
            waiterID,
            generation: runtimeSurfaceGeneration,
            readinessEpoch: runtimeReadinessEpoch,
            continuation: continuation
        )
        guard !Task.isCancelled else {
            await runtimeReadinessStore.cancel(waiterID)
            return false
        }

        if liveSurfaceForGhosttyAccess(reason: "runtime.ready.register") != nil {
            await runtimeReadinessStore.complete(waiterID, success: true)
        } else if !canCreateRuntimeSurface,
                  runtimeUnavailableReason != .awaitingRestore {
            await runtimeReadinessStore.complete(waiterID, success: false)
        }

        let store = runtimeReadinessStore
        return await withTaskCancellationHandler {
            for await result in events {
                await store.cancel(waiterID)
                return result
            }
            await store.cancel(waiterID)
            return false
        } onCancel: {
            Task { await store.cancel(waiterID) }
        }
    }

    @MainActor
    private func cancelRuntimeReadinessWaiter(_ waiterID: UUID) async {
        await runtimeReadinessStore.cancel(waiterID)
    }

    /// Completes every waiter for this lifecycle state. Called only after the
    /// runtime has been registered and initialized, or when its owner closes.
    func completeRuntimeReadiness(
        success: Bool,
        generation: UInt64? = nil,
        readinessEpoch: UInt64? = nil
    ) {
        let store = runtimeReadinessStore
        Task {
            await store.complete(
                success: success,
                readinessEpoch: readinessEpoch,
                currentGeneration: generation
            )
        }
    }
}
