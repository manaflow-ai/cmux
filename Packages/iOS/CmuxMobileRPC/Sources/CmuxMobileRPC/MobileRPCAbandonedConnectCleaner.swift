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

    func handOffLateCandidateToRegistry(
        task: Task<any CmxByteTransport, any Error>,
    ) async {
        await registry.handOffPhysicalCleanup(lease: lease) {
            do {
                let candidate = try await task.value
                if let cancellationCloseTask =
                    await cancellationClose?.task() {
                    await cancellationCloseTask.value
                }
                await candidate.close()
            } catch {
                if let cancellationCloseTask =
                    await cancellationClose?.task() {
                    await cancellationCloseTask.value
                }
            }
        }
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
