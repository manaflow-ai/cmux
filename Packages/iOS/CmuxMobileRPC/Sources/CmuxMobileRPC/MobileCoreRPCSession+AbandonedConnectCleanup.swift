internal import CMUXMobileCore
import Foundation
internal import os

/// Synchronously captures the physical close started by a connect task's
/// cancellation handler. The abandoned-connect cleaner combines this task
/// with any late candidate close under one route lease.
final class MobileRPCConnectCancellationClose: @unchecked Sendable {
    private let closeTask = OSAllocatedUnfairLock<
        Task<Void, Never>?
    >(initialState: nil)

    func start(_ candidate: any CmxByteTransport) {
        closeTask.withLock { closeTask in
            guard closeTask == nil else { return }
            closeTask = Task.detached {
                await candidate.close()
            }
        }
    }

    var task: Task<Void, Never>? {
        closeTask.withLock { $0 }
    }
}

extension MobileCoreRPCSession {
    func abandonConnectionTask(_ connecting: ConnectingTask) async {
        let cleanupID = UUID()
        let cleanupTask = Task.detached { [weak self] in
            do {
                let candidate = try await connecting.task.value
                if let cancellationCloseTask =
                    connecting.cancellationClose.task {
                    await cancellationCloseTask.value
                }
                await candidate.close()
            } catch {
                if let cancellationCloseTask =
                    connecting.cancellationClose.task {
                    await cancellationCloseTask.value
                }
            }
            await self?.abandonedConnectionCleanupDidFinish(cleanupID)
        }
        abandonedConnectionCleanupTasks[cleanupID] = cleanupTask
        // Teardown cannot return while the cancelled dial still owns the
        // active route lease. Transfer that exact physical lifetime first;
        // the registry then admits one bounded recovery without waiting for
        // a cancellation-ignoring connect or close to settle.
        await connectAttemptRegistry.handOffPhysicalCleanup(
            lease: connecting.lease
        ) {
            await cleanupTask.value
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
            cancellationClose: MobileRPCConnectCancellationClose(),
            cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
        )
    }

    func startAbandonedConnectionCleanup(
        task: Task<any CmxByteTransport, any Error>,
        lease: MobileRPCConnectAttemptLease?,
        cancellationClose: MobileRPCConnectCancellationClose =
            MobileRPCConnectCancellationClose(),
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

private struct MobileRPCAbandonedConnectCleaner: Sendable {
    struct CandidateClose: Sendable {
        let completedWithinDeadline: Bool
        let task: Task<Void, any Error>
    }

    let registry: MobileRPCConnectAttemptRegistry
    let lease: MobileRPCConnectAttemptLease?
    let cancellationClose: MobileRPCConnectCancellationClose

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
                    cancellationClose.task {
                    await cancellationCloseTask.value
                }
                await candidate.close()
            } catch {
                if let cancellationCloseTask =
                    cancellationClose.task {
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
    ) async -> CandidateClose {
        let closeTask = Task<Void, any Error> {
            if let cancellationCloseTask = cancellationClose.task {
                await cancellationCloseTask.value
            }
            await candidate.close()
        }
        do {
            try await RPCTaskTimeout().value(closeTask, timeoutNanoseconds: timeoutNanoseconds)
            return CandidateClose(
                completedWithinDeadline: true,
                task: closeTask
            )
        } catch {
            return CandidateClose(
                completedWithinDeadline: false,
                task: closeTask
            )
        }
    }

    func finishCancellationClose(
        timeoutNanoseconds: UInt64
    ) async {
        guard let cancellationCloseTask = cancellationClose.task else {
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
