import Foundation
@testable import CmuxMobileShell

extension MobileShellComposite {
    func connectionResourceSnapshotForTesting() -> MobileConnectionResourceSnapshot {
        let lifecycle = connectionLifecycle.resourceSnapshot
        return MobileConnectionResourceSnapshot(
            activeEpisodeCount: lifecycle.activeEpisodeCount,
            pendingRequestCount: lifecycle.pendingRequestCount,
            lifecycleTaskCount: connectionLifecycleTask == nil ? 0 : 1,
            retiredLifecycleTaskCount: connectionLifecycleRetiredTask == nil ? 0 : 1,
            lifecycleWaiterCount: connectionLifecycleRequestWaiters.count,
            networkObserverCount: networkPathObservationTask == nil ? 0 : 1,
            primaryTransportCount: remoteClient == nil ? 0 : 1,
            secondaryTransportCount: secondaryMacSubscriptions.count,
            listenerTaskCount: terminalEventListenerTask == nil ? 0 : 1,
            subscriptionTaskCount: terminalSubscriptionStartTask == nil ? 0 : 1,
            livenessProbeCount: renderGridLivenessProbeTask == nil ? 0 : 1,
            livenessTimerCount: renderGridLivenessTimer == nil ? 0 : 1,
            replayTaskCount: terminalReplayTasksBySurfaceID.count,
            byteContinuationCount: terminalByteContinuationsBySurfaceID.count,
            liveFontContinuationCount: terminalLiveFontContinuationsBySurfaceID.count
        )
    }
}

struct MobileConnectionResourceSnapshot: Equatable {
    let activeEpisodeCount: Int
    let pendingRequestCount: Int
    let lifecycleTaskCount: Int
    let retiredLifecycleTaskCount: Int
    let lifecycleWaiterCount: Int
    let networkObserverCount: Int
    let primaryTransportCount: Int
    let secondaryTransportCount: Int
    let listenerTaskCount: Int
    let subscriptionTaskCount: Int
    let livenessProbeCount: Int
    let livenessTimerCount: Int
    let replayTaskCount: Int
    let byteContinuationCount: Int
    let liveFontContinuationCount: Int
}
