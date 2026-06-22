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
                await cleaner.closeCandidate(
                    candidate,
                    timeoutNanoseconds: lateCloseTimeoutNanoseconds
                )
                await cleaner.clearFinishedConnectGate()
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
                await closeCandidate(candidate, timeoutNanoseconds: timeoutNanoseconds)
                await clearFinishedConnectGate()
            } catch {
            }
        }
    }

    func closeCandidate(_ candidate: any CmxByteTransport, timeoutNanoseconds: UInt64) async {
        let closeTask = Task<Void, any Error> {
            await candidate.close()
        }
        do {
            try await RPCTaskTimeout().value(closeTask, timeoutNanoseconds: timeoutNanoseconds)
        } catch {
            _ = try? await closeTask.value
        }
    }

    func clearFinishedConnectGate() async {
        guard tracksRouteGate else { return }
        await registry.clearFinishedConnect(lease: lease)
    }
}
