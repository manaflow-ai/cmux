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
        Task.detached { [connectAttemptRegistry] in
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
                let didClose = await cleaner.closeCandidate(
                    candidate,
                    timeoutNanoseconds: lateCloseTimeoutNanoseconds
                )
                if didClose {
                    await cleaner.clearFinishedConnectGate()
                } else {
                    await cleaner.clearTimedOutAbandonedCleanupGate()
                }
            } catch MobileShellConnectionError.requestTimedOut {
                if tracksRouteGate {
                    await connectAttemptRegistry.clearTimedOutAbandonedCleanup(lease: lease)
                }
                cleaner.closeLateAbandonedCandidate(
                    task: task,
                    timeoutNanoseconds: lateCloseTimeoutNanoseconds
                )
            } catch {
                await cleaner.clearFinishedConnectGate()
            }
        }
    }
}

private struct MobileRPCAbandonedConnectCleaner: Sendable {
    let registry: MobileRPCConnectAttemptRegistry
    let lease: MobileRPCConnectAttemptLease?
    let tracksRouteGate: Bool

    func closeLateAbandonedCandidate(
        task: Task<any CmxByteTransport, any Error>,
        timeoutNanoseconds: UInt64
    ) {
        Task.detached {
            let taskTimeout = RPCTaskTimeout()
            do {
                let candidate = try await taskTimeout.value(
                    task,
                    timeoutNanoseconds: timeoutNanoseconds
                )
                let didClose = await closeCandidate(candidate, timeoutNanoseconds: timeoutNanoseconds)
                if didClose {
                    await clearFinishedConnectGate()
                } else {
                    await clearTimedOutAbandonedCleanupGate()
                }
            } catch {
            }
        }
    }

    func closeCandidate(_ candidate: any CmxByteTransport, timeoutNanoseconds: UInt64) async -> Bool {
        let closeTask = Task<Void, any Error> {
            await candidate.close()
        }
        do {
            try await RPCTaskTimeout().value(closeTask, timeoutNanoseconds: timeoutNanoseconds)
            return true
        } catch {
            closeTask.cancel()
            return false
        }
    }

    func clearFinishedConnectGate() async {
        guard tracksRouteGate else { return }
        await registry.clearFinishedConnect(lease: lease)
    }

    func clearTimedOutAbandonedCleanupGate() async {
        guard tracksRouteGate else { return }
        await registry.markAbandoned(lease: lease)
        await registry.clearTimedOutAbandonedCleanup(lease: lease)
    }
}
