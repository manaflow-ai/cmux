internal import CMUXMobileCore

struct MobileRPCAbandonedConnectCleaner: Sendable {
    let registry: MobileRPCConnectAttemptRegistry
    let lease: MobileRPCConnectAttemptLease?
    let cancellationClose: MobileRPCConnectCancellationClose?

    func finishLateAbandonedCandidate(
        task: Task<any CmxByteTransport, any Error>,
        timeoutNanoseconds: UInt64
    ) async {
        do {
            let candidate = try await RPCTaskTimeout().value(
                task,
                timeoutNanoseconds: timeoutNanoseconds
            )
            let close = await closeCandidate(
                candidate,
                timeoutNanoseconds: timeoutNanoseconds
            )
            if close.completedWithinDeadline {
                await clearFinishedConnectGate()
            } else {
                await handOffCloseToRegistry(close.task)
            }
        } catch MobileShellConnectionError.requestTimedOut {
            await handOffLateCandidateToRegistry(task: task)
        } catch {
            await finishCancellationClose(
                timeoutNanoseconds: timeoutNanoseconds
            )
        }
    }

    /// The single owner of the abandoned-dial cleanup protocol: track the
    /// late-close receipt first, then hand off physical cleanup for the
    /// lease. Returns the route-cleanup task so callers can observe when the
    /// physical milestone resolves.
    @discardableResult
    func handOffLateCandidateToRegistry(
        task: Task<any CmxByteTransport, any Error>
    ) async -> Task<Void, Never> {
        let lateCleanup = Task.detached {
            do {
                let candidate = try await task.value
                await candidate.close()
            } catch {}
        }
        await registry.trackPostCloseCleanup {
            await lateCleanup.value
        }

        // The cancellation close is the physical route milestone. The
        // cancelled connect task may ignore Swift cancellation forever, but a
        // late result is generation-rejected and closed by `lateCleanup`.
        let cancellationClose = cancellationClose
        let routeCleanup = Task {
            if let cancellationCloseTask = await cancellationClose?.task() {
                await cancellationCloseTask.value
            } else {
                await lateCleanup.value
            }
        }
        await registry.handOffPhysicalCleanup(lease: lease) {
            await routeCleanup.value
        }
        return routeCleanup
    }

    func handOffCloseToRegistry(
        _ closeTask: Task<Void, any Error>
    ) async {
        await registry.handOffPhysicalCleanup(lease: lease) {
            _ = await closeTask.result
        }
    }

    func closeCandidate(
        _ candidate: any CmxByteTransport,
        timeoutNanoseconds: UInt64
    ) async -> MobileRPCAbandonedCandidateClose {
        let closeTask = Task<Void, any Error> {
            if let cancellationCloseTask = await cancellationClose?.task() {
                await cancellationCloseTask.value
            }
            await candidate.close()
        }
        do {
            try await RPCTaskTimeout().value(
                closeTask,
                timeoutNanoseconds: timeoutNanoseconds
            )
            return MobileRPCAbandonedCandidateClose(
                completedWithinDeadline: true,
                task: closeTask
            )
        } catch {
            return MobileRPCAbandonedCandidateClose(
                completedWithinDeadline: false,
                task: closeTask
            )
        }
    }

    func finishCancellationClose(
        timeoutNanoseconds: UInt64
    ) async {
        guard let cancellationCloseTask = await cancellationClose?.task() else {
            await clearFinishedConnectGate()
            return
        }
        let closeTask = Task<Void, any Error> {
            await cancellationCloseTask.value
        }
        do {
            try await RPCTaskTimeout().value(
                closeTask,
                timeoutNanoseconds: timeoutNanoseconds
            )
            await clearFinishedConnectGate()
        } catch {
            await handOffCloseToRegistry(closeTask)
        }
    }

    func clearFinishedConnectGate() async {
        await registry.finishConnect(lease: lease)
    }
}
