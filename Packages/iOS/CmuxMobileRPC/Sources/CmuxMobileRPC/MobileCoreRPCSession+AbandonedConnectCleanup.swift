internal import CMUXMobileCore
import Foundation

extension MobileCoreRPCSession {
    func abandonConnectionTask(_ connecting: ConnectingTask) async {
        let cleanupID = UUID()
        let cleanupTask = Task.detached {
            do {
                let candidate = try await connecting.task.value
                if let cancellationCloseTask =
                    await connecting.cancellationClose.task() {
                    await cancellationCloseTask.value
                }
                await candidate.close()
            } catch {
                if let cancellationCloseTask =
                    await connecting.cancellationClose.task() {
                    await cancellationCloseTask.value
                }
            }
        }
        let registrationTask = Task {
            [connectAttemptRegistry] in
            await connectAttemptRegistry.handOffPhysicalCleanup(
                lease: connecting.lease
            ) {
                await cleanupTask.value
            }
        }
        abandonedConnectionCleanupTasks[cleanupID] = registrationTask
        // Teardown cannot return while the cancelled dial still owns the
        // active route lease. Transfer that exact physical lifetime first;
        // the registry then admits one bounded recovery without waiting for
        // a cancellation-ignoring connect or close to settle.
        await registrationTask.value
        abandonedConnectionCleanupTasks[cleanupID] = nil
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
