internal import CMUXMobileCore
import Foundation

extension MobileCoreRPCSession {
    func abandonConnectionTask(_ connecting: ConnectingTask) async {
        let cleanupID = UUID()
        // Teardown cannot return while the cancelled dial still owns the
        // active route lease. The cleaner tracks the late-close receipt and
        // transfers that exact physical lifetime; the late task result is
        // tracked separately and consumes no admission.
        let cleaner = MobileRPCAbandonedConnectCleaner(
            registry: connectAttemptRegistry,
            lease: connecting.lease,
            cancellationClose: connecting.cancellationClose
        )
        let routeCleanupTask = await cleaner.handOffLateCandidateToRegistry(
            task: connecting.task
        )
        abandonedConnectionCleanupTasks[cleanupID] = routeCleanupTask
        Task { [weak self] in
            await routeCleanupTask.value
            await self?.abandonedConnectionCleanupDidFinish(cleanupID)
        }
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
        cancellationClose: MobileRPCConnectCancellationClose? = nil,
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
                cancellationClose: cancellationClose
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
                await cleaner.finishCancellationClose(
                    timeoutNanoseconds: lateCloseTimeoutNanoseconds
                )
            }
            await self?.abandonedConnectionCleanupDidFinish(cleanupID)
        }
        abandonedConnectionCleanupTasks[cleanupID] = cleanupTask
    }

    private func abandonedConnectionCleanupDidFinish(_ cleanupID: UUID) {
        abandonedConnectionCleanupTasks[cleanupID] = nil
    }
}
