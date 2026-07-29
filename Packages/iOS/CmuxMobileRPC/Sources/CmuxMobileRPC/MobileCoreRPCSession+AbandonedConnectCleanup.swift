internal import CMUXMobileCore
import Foundation

extension MobileCoreRPCSession {
    func abandonConnectionTask(_ connecting: ConnectingTask) async {
        startAbandonedConnectionCleanup(
            task: connecting.task,
            lease: connecting.lease,
            cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
        )
    }

    func closeUninstalledConnectedCandidate(
        _ candidate: any CmxByteTransport,
        lease: MobileRPCConnectAttemptLease?
    ) {
        let task = Task<any CmxByteTransport, any Error> {
            candidate
        }
        startAbandonedConnectionCleanup(
            task: task,
            lease: lease,
            cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
        )
    }

    func startAbandonedConnectionCleanup(
        task: Task<any CmxByteTransport, any Error>,
        lease: MobileRPCConnectAttemptLease?,
        cleanupTimeoutNanoseconds: UInt64,
        lateCloseTimeoutNanoseconds: UInt64
    ) {
        let cleanupID = UUID()
        let cleanupTask = Task.detached {
            [connectAttemptRegistry, weak self] in
            let taskTimeout = RPCTaskTimeout()
            let cleaner = MobileRPCAbandonedConnectCleaner(
                registry: connectAttemptRegistry,
                lease: lease
            )
            do {
                let candidate = try await taskTimeout.value(
                    task,
                    timeoutNanoseconds: cleanupTimeoutNanoseconds
                )
                let close = await cleaner.closeCandidate(
                    candidate,
                    timeoutNanoseconds: lateCloseTimeoutNanoseconds
                )
                if close.completedWithinDeadline {
                    await cleaner.clearFinishedConnectGate()
                } else {
                    await cleaner.handOffCloseToRegistry(close.task)
                }
            } catch MobileShellConnectionError.requestTimedOut {
                await cleaner.finishLateAbandonedCandidate(
                    task: task,
                    timeoutNanoseconds: lateCloseTimeoutNanoseconds
                )
            } catch {
                await cleaner.clearFinishedConnectGate()
            }
            await self?.abandonedConnectionCleanupDidFinish(cleanupID)
        }
        abandonedConnectionCleanupTasks[cleanupID] = cleanupTask
    }

    private func abandonedConnectionCleanupDidFinish(_ cleanupID: UUID) {
        abandonedConnectionCleanupTasks[cleanupID] = nil
    }
}

private struct MobileRPCAbandonedConnectCleaner: Sendable {
    struct CandidateClose: Sendable {
        let completedWithinDeadline: Bool
        let task: Task<Void, any Error>
    }

    let registry: MobileRPCConnectAttemptRegistry
    let lease: MobileRPCConnectAttemptLease?

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
            await clearFinishedConnectGate()
        }
    }

    func handOffLateCandidateToRegistry(
        task: Task<any CmxByteTransport, any Error>,
    ) async {
        await registry.handOffPhysicalCleanup(lease: lease) {
            do {
                let candidate = try await task.value
                await candidate.close()
            } catch {
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
    ) async -> CandidateClose {
        let closeTask = Task<Void, any Error> {
            await candidate.close()
        }
        do {
            try await RPCTaskTimeout().value(closeTask, timeoutNanoseconds: timeoutNanoseconds)
            return CandidateClose(
                completedWithinDeadline: true,
                task: closeTask
            )
        } catch {
            closeTask.cancel()
            return CandidateClose(
                completedWithinDeadline: false,
                task: closeTask
            )
        }
    }

    func clearFinishedConnectGate() async {
        await registry.finishConnect(lease: lease)
    }
}
