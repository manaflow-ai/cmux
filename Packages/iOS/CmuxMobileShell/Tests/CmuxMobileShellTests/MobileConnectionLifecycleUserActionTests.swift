import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileConnectionLifecycleUserActionTests {
    @Test func staleShellFinishCannotDropNewerEpisodeTaskHandle() {
        let store = MobileShellComposite.preview()
        guard case .start(let oldEpisode) = store.connectionLifecycle.request(
            .manualRetry,
            health: .healthy
        ) else {
            Issue.record("first episode must start")
            return
        }
        store.connectionLifecycle.reset()
        guard case .start(let newEpisode) = store.connectionLifecycle.request(
            .manualRetry,
            health: .healthy
        ) else {
            Issue.record("replacement episode must start")
            return
        }
        store.connectionLifecycleTask = Task {}

        store.finishConnectionLifecycleEpisode(id: oldEpisode.id)

        #expect(store.connectionLifecycle.ownsEpisode(newEpisode.id))
        #expect(store.connectionLifecycleTask != nil)
    }

    @Test func lifecycleResetResolvesTheStoredMacRestoringGate() {
        let store = MobileShellComposite.preview()
        _ = store.connectionLifecycle.requestStoredMacReconnect(
            stackUserID: "user-1",
            health: .disconnected
        )

        #expect(store.isReconnectingStoredMac)
        #expect(!store.didFinishStoredMacReconnectAttempt)
        store.storedMacReconnectTargetDeviceID = "mac-being-restored"

        store.resetConnectionLifecycle()

        #expect(!store.isReconnectingStoredMac)
        #expect(store.didFinishStoredMacReconnectAttempt)
        #expect(store.storedMacReconnectTargetDeviceID == nil)
    }

    @Test func manualRetrySupersedesAnOwnedStoredMacReconnect() {
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: DelayedTeamPairedMacStore(
                recordsByTeam: [:],
                blockedTeams: []
            ),
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        let oldRequest = store.connectionLifecycle.requestStoredMacReconnect(
            stackUserID: "user-1",
            health: .disconnected
        )
        guard case .start(let oldEpisode) = oldRequest.effect else {
            Issue.record("stored Mac reconnect must start one owned episode")
            return
        }

        store.retryMobileConnection()

        let replacement = store.connectionLifecycle.activeEpisode
        #expect(replacement?.id != oldEpisode.id)
        #expect(replacement?.kind == .reconnect)
        #expect(replacement?.triggers == [.manualRetry])
        #expect(!store.didFinishStoredMacReconnectAttempt)
    }

    @Test func manualPairingCancelsOwnedReconnectAndResolvesItsCaller() async {
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [:],
            blockedTeams: [""]
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitUntilLoadStarted(teamID: nil)
        defer { Task { await pairedMacStore.release(teamID: nil) } }

        store.prepareForManualPairing()

        #expect(await reconnect.value == false)
        #expect(store.connectionLifecycle.activeEpisode == nil)
        #expect(store.connectionLifecycle.resourceSnapshot.activeEpisodeCount == 0)
        #expect(store.connectionLifecycle.resourceSnapshot.pendingRequestCount == 0)
        #expect(store.connectionLifecycleRequestWaiters.isEmpty)
        #expect(store.didFinishStoredMacReconnectAttempt)
    }

    @Test func missingReconnectDependenciesResolveTheStoredMacGate() async {
        let store = MobileShellComposite(
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )

        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(!connected)
        #expect(store.didFinishStoredMacReconnectAttempt)
        #expect(store.connectionRecoveryFailed)
        #expect(store.connectionLifecycle.activeEpisode == nil)
        #expect(store.connectionLifecycle.resourceSnapshot.pendingRequestCount == 0)
    }

    @Test func teamChangeReplacesStoredMacRecoveryWithNewScopeEpisode() {
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: DelayedTeamPairedMacStore(
                recordsByTeam: [:],
                blockedTeams: []
            ),
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        let oldRequest = store.connectionLifecycle.requestStoredMacReconnect(
            stackUserID: "user-1",
            health: .disconnected
        )
        guard case .start(let oldEpisode) = oldRequest.effect else {
            Issue.record("old-team reconnect must start")
            return
        }

        store.currentTeamDidChange()

        let replacement = store.connectionLifecycle.activeEpisode
        #expect(replacement?.id != oldEpisode.id)
        #expect(replacement?.kind == .reconnect)
        #expect(replacement?.reconnectStackUserID == "user-1")
        #expect(!store.didFinishStoredMacReconnectAttempt)
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
