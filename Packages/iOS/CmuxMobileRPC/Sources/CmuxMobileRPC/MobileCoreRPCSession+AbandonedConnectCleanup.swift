internal import CMUXMobileCore
import Foundation

extension MobileCoreRPCSession {
    func abandonConnectionTask(_ connecting: ConnectingTask) async {
        startAbandonedConnectionCleanup(
            task: connecting.task,
            lease: connecting.lease,
            tracksRouteGate: true,
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
            tracksRouteGate: true,
            cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
        )
    }

    func startAbandonedConnectionCleanup(
        task: Task<any CmxByteTransport, any Error>,
        lease: MobileRPCConnectAttemptLease?,
        tracksRouteGate: Bool,
        cleanupTimeoutNanoseconds: UInt64,
        lateCloseTimeoutNanoseconds: UInt64
    ) {
        let cleanupID = UUID()
        let cleanupTask = Task.detached {
            [connectAttemptRegistry, weak self] in
            let taskTimeout = RPCTaskTimeout()
            let cleaner = MobileRPCAbandonedConnectCleaner(
                registry: connectAttemptRegistry,
                lease: lease,
                tracksRouteGate: tracksRouteGate
            )
            await cleaner.markAbandoned()
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
                    await cleaner.releaseTimedOutCleanupGate()
                    cleaner.watchCloseToPhysicalCompletion(close.task)
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
    let tracksRouteGate: Bool

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
                await releaseTimedOutCleanupGate()
                watchCloseToPhysicalCompletion(close.task)
            }
        } catch MobileShellConnectionError.requestTimedOut {
            await releaseTimedOutCleanupGate()
            watchLateCandidateToPhysicalCompletion(task: task)
        } catch {
            await clearFinishedConnectGate()
        }
    }

    func watchLateCandidateToPhysicalCompletion(
        task: Task<any CmxByteTransport, any Error>,
    ) {
        Task.detached {
            do {
                let candidate = try await task.value
                await candidate.close()
            } catch {
            }
            await clearFinishedConnectGate()
        }
    }

    func watchCloseToPhysicalCompletion(_ closeTask: Task<Void, any Error>) {
        Task.detached {
            _ = await closeTask.result
            await clearFinishedConnectGate()
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
        guard tracksRouteGate else { return }
        await registry.clearFinishedConnect(lease: lease)
    }

    func markAbandoned() async {
        guard tracksRouteGate else { return }
        await registry.markAbandoned(lease: lease)
    }

    func releaseTimedOutCleanupGate() async {
        guard tracksRouteGate else { return }
        await registry.clearTimedOutAbandonedCleanup(lease: lease)
    }
}
