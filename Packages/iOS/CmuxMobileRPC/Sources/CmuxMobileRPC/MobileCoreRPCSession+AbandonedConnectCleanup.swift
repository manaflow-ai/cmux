internal import CMUXMobileCore
import Foundation

extension MobileCoreRPCSession {
    func abandonConnectionTask(_ connecting: ConnectingTask) async {
        await connectAttemptRegistry.markAbandoned(lease: connecting.lease)
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
                    _ = await close.task.result
                    await cleaner.clearFinishedConnectGate()
                }
            } catch MobileShellConnectionError.requestTimedOut {
                await cleaner.closeLateAbandonedCandidate(
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

    func closeLateAbandonedCandidate(
        task: Task<any CmxByteTransport, any Error>,
        timeoutNanoseconds: UInt64
    ) async {
        let taskTimeout = RPCTaskTimeout()
        do {
            let candidate = try await taskTimeout.value(
                task,
                timeoutNanoseconds: timeoutNanoseconds
            )
            let close = await closeCandidate(
                candidate,
                timeoutNanoseconds: timeoutNanoseconds
            )
            if !close.completedWithinDeadline {
                _ = await close.task.result
            }
        } catch {
            // Both bounded registry gates have expired. Keep this tracked
            // watcher alive until the cancellation-ignoring connect actually
            // settles, then close any late candidate to physical completion.
            do {
                let candidate = try await task.value
                await candidate.close()
            } catch {
            }
        }
        // Admission stays closed throughout both bounded observation windows
        // and any cancellation-ignoring tail. A physically unresolved owner
        // must not be traded for a retry budget that can accumulate transports.
        await clearFinishedConnectGate()
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
}
