import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct MobileConnectionLifecycleStateMachineTests {
    @Test func mixedBackgroundTriggersBecomeOneEpisode() {
        let now = Date()
        var reducer = MobileConnectionLifecycleStateMachine()
        reducer.becameInactive(at: now)
        for _ in 0..<200 {
            #expect(reducer.request(.networkPathChanged, health: .healthy) == nil)
            #expect(reducer.request(.presenceRoutesChanged, health: .healthy) == nil)
        }

        let effect = reducer.becameActive(
            at: now.addingTimeInterval(31),
            shortDwellThreshold: 30,
            health: .healthy
        )
        guard case .start(let episode) = effect else {
            Issue.record("one foreground episode must own every deferred trigger")
            return
        }
        #expect(episode.kind == .streamRepair)
        #expect(reducer.activeEpisode?.id == episode.id)
        #expect(reducer.request(.networkPathChanged, health: .healthy) == nil)
    }

    @Test func staleCompletionAndResetCannotCommit() {
        var reducer = MobileConnectionLifecycleStateMachine()
        guard case .start(let episode) = reducer.request(.manualRetry, health: .healthy) else {
            Issue.record("manual retry must start one episode")
            return
        }

        #expect(reducer.complete(id: episode.id &+ 1, health: .healthy) == nil)
        #expect(reducer.ownsEpisode(episode.id))
        reducer.reset()
        #expect(!reducer.ownsEpisode(episode.id))
        #expect(reducer.activeEpisode == nil)
    }

    @Test func recoveryPresentationStateBelongsToTheLifecycleOwner() {
        var reducer = MobileConnectionLifecycleStateMachine()
        #expect(!reducer.isRecovering)
        #expect(!reducer.recoveryFailed)

        guard case .start(let failedEpisode) = reducer.request(
            .networkPathChanged,
            health: .disconnected
        ) else {
            Issue.record("network recovery must start one episode")
            return
        }
        #expect(reducer.isRecovering)
        #expect(!reducer.recoveryFailed)

        #expect(reducer.complete(
            id: failedEpisode.id,
            health: .disconnected,
            succeeded: false
        ) == nil)
        #expect(!reducer.isRecovering)
        #expect(reducer.recoveryFailed)

        guard case .start(let retryEpisode) = reducer.request(
            .manualRetry,
            health: .disconnected
        ) else {
            Issue.record("manual retry must replace failure with an owned episode")
            return
        }
        #expect(reducer.isRecovering)
        #expect(!reducer.recoveryFailed)

        #expect(reducer.complete(
            id: retryEpisode.id,
            health: .healthy,
            succeeded: true
        ) == nil)
        #expect(!reducer.isRecovering)
        #expect(!reducer.recoveryFailed)
    }

    @Test func twoHundredMixedCyclesKeepLifecycleResourcesBounded() {
        var reducer = MobileConnectionLifecycleStateMachine()

        for cycle in 0..<200 {
            let health: MobileConnectionLifecycleHealthSnapshot = cycle.isMultiple(of: 2)
                ? .healthy
                : .disconnected
            guard case .start(let episode) = reducer.request(
                .networkPathChanged,
                health: health
            ) else {
                Issue.record("cycle \(cycle) must start one episode")
                return
            }
            #expect(reducer.request(.presenceRoutesChanged, health: health) == nil)

            let active = reducer.resourceSnapshot
            #expect(active.activeEpisodeCount == 1)
            #expect(active.pendingRequestCount == 0)

            #expect(reducer.complete(
                id: episode.id,
                health: health,
                succeeded: true
            ) == nil)
            let idle = reducer.resourceSnapshot
            #expect(idle.activeEpisodeCount == 0)
            #expect(idle.pendingRequestCount == 0)
        }
    }

    @Test func connectedRecoveryTriggersRepairTheStreamWithoutReplacingTheClient() {
        for trigger in [
            MobileConnectionLifecycleTrigger.networkPathChanged,
            .presenceRoutesChanged,
            .manualRetry,
        ] {
            var reducer = MobileConnectionLifecycleStateMachine()
            guard case .start(let episode) = reducer.request(trigger, health: .healthy) else {
                Issue.record("connected recovery must start one episode for \(trigger)")
                continue
            }

            #expect(episode.kind == .streamRepair)
        }
    }

    @Test func joinedStreamRepairRequestsAccumulateTheirTriggers() {
        var reducer = MobileConnectionLifecycleStateMachine()
        guard case .start(let episode) = reducer.request(
            .networkPathChanged,
            health: .healthy
        ) else {
            Issue.record("network path recovery must start one episode")
            return
        }

        #expect(reducer.request(.eventStreamLost, health: .healthy) == nil)
        #expect(reducer.activeEpisode?.id == episode.id)
        #expect(reducer.activeEpisode?.triggers == [.networkPathChanged, .eventStreamLost])
    }

    @Test func deferredReconnectRetainsItsIdentityAndCompletionOwnership() {
        var reducer = MobileConnectionLifecycleStateMachine()
        guard case .start(let streamEpisode) = reducer.request(
            .networkPathChanged,
            health: .healthy
        ) else {
            Issue.record("stream repair must start")
            return
        }
        let reconnect = reducer.requestStoredMacReconnect(
            stackUserID: "user-1",
            health: .healthy
        )
        #expect(reconnect.effect == nil)

        guard case .start(let reconnectEpisode) = reducer.complete(
            id: streamEpisode.id,
            health: .healthy
        ) else {
            Issue.record("deferred reconnect must start after stream repair")
            return
        }
        #expect(reducer.drainCompletedRequestIDs().isEmpty)
        #expect(reconnectEpisode.kind == .reconnect)
        #expect(reconnectEpisode.reconnectStackUserID == "user-1")
        #expect(reconnectEpisode.requestIDs == [reconnect.id])

        #expect(reducer.complete(id: reconnectEpisode.id, health: .healthy) == nil)
        #expect(reducer.drainCompletedRequestIDs() == [reconnect.id])
    }

    @Test func reconnectRequestsOnlyJoinAnEpisodeWithTheSameIdentity() {
        var reducer = MobileConnectionLifecycleStateMachine()
        let first = reducer.requestStoredMacReconnect(
            stackUserID: "user-1",
            health: .disconnected
        )
        guard case .start(let firstEpisode) = first.effect else {
            Issue.record("first reconnect must start")
            return
        }
        let joined = reducer.requestStoredMacReconnect(
            stackUserID: "user-1",
            health: .disconnected
        )
        let deferred = reducer.requestStoredMacReconnect(
            stackUserID: "user-2",
            health: .disconnected
        )
        #expect(joined.effect == nil)
        #expect(deferred.effect == nil)
        #expect(reducer.activeEpisode?.requestIDs == [first.id, joined.id])

        guard case .start(let secondEpisode) = reducer.complete(
            id: firstEpisode.id,
            health: .disconnected
        ) else {
            Issue.record("different identity must receive a separate episode")
            return
        }
        #expect(reducer.drainCompletedRequestIDs() == [first.id, joined.id])
        #expect(secondEpisode.reconnectStackUserID == "user-2")
        #expect(secondEpisode.requestIDs == [deferred.id])
    }

    @Test func completingAnEpisodeWhileInactiveLeavesPendingRecoveryDeferred() {
        let now = Date()
        var reducer = MobileConnectionLifecycleStateMachine()
        guard case .start(let activeEpisode) = reducer.request(
            .manualRetry,
            health: .disconnected
        ) else {
            Issue.record("initial reconnect must start")
            return
        }
        reducer.becameInactive(at: now)
        #expect(reducer.request(.networkPathChanged, health: .disconnected) == nil)

        #expect(reducer.complete(id: activeEpisode.id, health: .disconnected) == nil)
        #expect(reducer.activeEpisode == nil)

        guard case .start(let resumedEpisode) = reducer.becameActive(
            at: now.addingTimeInterval(31),
            shortDwellThreshold: 30,
            health: .disconnected
        ) else {
            Issue.record("foreground activation must start the deferred recovery")
            return
        }
        #expect(resumedEpisode.triggers == [.networkPathChanged])
    }

    @Test func foregroundReconnectCanJoinARequestForTheCurrentIdentity() {
        let now = Date()
        var reducer = MobileConnectionLifecycleStateMachine()
        reducer.becameInactive(at: now)
        guard case .start(let foregroundEpisode) = reducer.becameActive(
            at: now.addingTimeInterval(31),
            shortDwellThreshold: 30,
            health: .disconnected,
            reconnectStackUserID: "user-1"
        ) else {
            Issue.record("foreground reconnect must start")
            return
        }
        let reconnect = reducer.requestStoredMacReconnect(
            stackUserID: "user-1",
            health: .disconnected
        )

        #expect(reconnect.effect == nil)
        #expect(reducer.activeEpisode?.id == foregroundEpisode.id)
        #expect(reducer.activeEpisode?.requestIDs.contains(reconnect.id) == true)
    }

    @MainActor
    @Test func staleShellFinishCannotDropNewerEpisodeTaskHandle() {
        let store = MobileShellComposite.preview()
        let health = MobileConnectionLifecycleHealthSnapshot.healthy
        guard case .start(let oldEpisode) = store.connectionLifecycle.request(
            .manualRetry,
            health: health
        ) else {
            Issue.record("first episode must start")
            return
        }
        store.connectionLifecycle.reset()
        guard case .start(let newEpisode) = store.connectionLifecycle.request(
            .manualRetry,
            health: health
        ) else {
            Issue.record("replacement episode must start")
            return
        }
        store.connectionLifecycleTask = Task {}

        store.finishConnectionLifecycleEpisode(id: oldEpisode.id)

        #expect(store.connectionLifecycle.ownsEpisode(newEpisode.id))
        #expect(store.connectionLifecycleTask != nil)
    }

    @MainActor
    @Test func lifecycleResetResolvesTheStoredMacRestoringGate() {
        let store = MobileShellComposite.preview()
        _ = store.connectionLifecycle.requestStoredMacReconnect(
            stackUserID: "user-1",
            health: .disconnected
        )

        #expect(store.isReconnectingStoredMac)
        #expect(!store.didFinishStoredMacReconnectAttempt)

        store.resetConnectionLifecycle()

        #expect(!store.isReconnectingStoredMac)
        #expect(store.didFinishStoredMacReconnectAttempt)
    }
}

private extension MobileConnectionLifecycleHealthSnapshot {
    static var healthy: Self {
        Self(
            connected: true,
            hasClient: true,
            hasListener: true,
            eventStreamFresh: true,
            canReconnectPersistedMac: true
        )
    }

    static var disconnected: Self {
        Self(
            connected: false,
            hasClient: false,
            hasListener: false,
            eventStreamFresh: false,
            canReconnectPersistedMac: true
        )
    }
}
