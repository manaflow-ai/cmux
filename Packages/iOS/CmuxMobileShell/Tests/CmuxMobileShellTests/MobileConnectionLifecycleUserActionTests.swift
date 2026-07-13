import CMUXMobileCore
import CmuxMobilePairedMac
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

    @Test func signOutClearsStoredMacReconnectTargetOwnership() {
        let store = MobileShellComposite.preview()
        store.storedMacReconnectTargetDeviceID = "mac-being-restored"

        store.signOut()

        #expect(store.storedMacReconnectTargetDeviceID == nil)
    }

    @Test func deletingLastVisibleMacClearsReconnectTargetOwnership() {
        let store = MobileShellComposite.preview()
        store.storedMacReconnectTargetDeviceID = "mac-being-restored"

        store.clearSavedMacHintAfterDeletingLastVisibleMacIfNeeded()

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

    @Test func forgettingDuringReconnectCannotBeUndoneByLatePersistence() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "": [storedMac(id: "test-mac", route: route, isActive: true)],
            ],
            blockedTeams: []
        )
        await pairedMacStore.gateUpsert(macDeviceID: "test-mac")
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(router: router, box: box),
                now: { clock.now }
            ),
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability()
        )
        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitUntilUpsertStarted(macDeviceID: "test-mac")

        await store.forgetStoredMac(macDeviceID: "test-mac")
        await pairedMacStore.releaseUpsert(macDeviceID: "test-mac")
        await pairedMacStore.waitUntilUpsertCount(1)
        _ = await reconnect.value

        let rows = try await pairedMacStore.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!rows.contains { $0.macDeviceID == "test-mac" })
        let scope = try #require(await store.currentScopeSnapshot())
        #expect(await store.isForgottenMacDeviceID("test-mac", scope: scope))
    }

    @Test func forgettingConnectedFallbackMacDisconnectsItsLiveClient() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "": [storedMac(id: "test-mac", route: route, isActive: false)],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(router: router, box: box),
                now: { clock.now }
            ),
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability()
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.connectionState == .connected)
        #expect(store.foregroundMacDeviceIDForTesting() == "test-mac")

        await store.forgetStoredMac(macDeviceID: "test-mac")

        #expect(store.connectionState == .disconnected)
        #expect(store.remoteClient == nil)
    }

    @Test func staleOwnedDeadlineCannotOverwriteSuccessfulCompletion() async {
        let deadline = ControlledStoredMacReconnectDeadline()
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [:],
            blockedTeams: [""]
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            storedMacReconnectDeadline: { await deadline.wait() }
        )
        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitUntilLoadStarted(teamID: nil)
        await deadline.waitUntilArmed()
        defer { Task { await pairedMacStore.release(teamID: nil) } }
        let episodeID = try! #require(store.connectionLifecycle.activeEpisode?.id)

        store.finishConnectionLifecycleEpisode(id: episodeID, succeeded: true)
        #expect(await reconnect.value == false)
        await deadline.expire()

        #expect(!store.connectionRecoveryFailed)
        #expect(store.connectionError == nil)
        #expect(store.connectionErrorGuidance == nil)
        #expect(store.connectionLifecycle.activeEpisode == nil)
    }

    @Test func staleOwnedDeadlineCannotOverwriteManualPairingCancellation() async {
        let deadline = ControlledStoredMacReconnectDeadline()
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [:],
            blockedTeams: [""]
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            storedMacReconnectDeadline: { await deadline.wait() }
        )
        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitUntilLoadStarted(teamID: nil)
        await deadline.waitUntilArmed()
        defer { Task { await pairedMacStore.release(teamID: nil) } }

        store.prepareForManualPairing()
        #expect(await reconnect.value == false)
        await deadline.expire()

        #expect(!store.connectionRecoveryFailed)
        #expect(store.connectionError == nil)
        #expect(store.connectionErrorGuidance == nil)
        #expect(store.connectionLifecycle.activeEpisode == nil)
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

    @Test func repeatedTeamChangesReplayStoredMacRecoveryForLatestScope() async throws {
        let team = MutableTeamID("team-a")
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [:],
            blockedTeams: ["team-a"]
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { await team.value }
        )
        let oldReconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitUntilLoadStarted(teamID: "team-a")

        await team.set("team-b")
        store.currentTeamDidChange()
        #expect(await oldReconnect.value == false)
        #expect(await pairedMacStore.currentLoadStartCount(teamID: "team-b") == 0)

        await team.set("team-c")
        store.currentTeamDidChange()
        #expect(await pairedMacStore.currentLoadStartCount(teamID: "team-b") == 0)
        #expect(await pairedMacStore.currentLoadStartCount(teamID: "team-c") == 0)

        await pairedMacStore.release(teamID: "team-a")

        #expect(try await pollUntil {
            await pairedMacStore.currentLoadStartCount(teamID: "team-c") == 1
        })
        #expect(await pairedMacStore.currentLoadStartCount(teamID: "team-b") == 0)
        #expect(try await pollUntil {
            store.connectionResourceSnapshotForTesting().activeEpisodeCount == 0
                && store.connectionResourceSnapshotForTesting().retiredLifecycleTaskCount == 0
        })
        let resources = store.connectionResourceSnapshotForTesting()
        #expect(resources.pendingRequestCount == 0)
        #expect(resources.lifecycleWaiterCount == 0)
    }

    @Test func teamChangesPreserveInactiveQueuedStoredMacReconnect() async throws {
        let team = MutableTeamID("team-a")
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [:],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { await team.value }
        )
        store.suspendForegroundRefresh()
        let oldReconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        #expect(try await pollUntil {
            store.connectionLifecycle.resourceSnapshot.pendingRequestCount == 1
                && store.connectionLifecycleRequestWaiters.count == 1
        })

        await team.set("team-b")
        store.currentTeamDidChange()
        #expect(await oldReconnect.value == false)
        #expect(store.connectionLifecycle.resourceSnapshot.pendingRequestCount == 1)

        await team.set("team-c")
        store.currentTeamDidChange()
        #expect(store.connectionLifecycle.resourceSnapshot.pendingRequestCount == 1)

        store.resumeForegroundRefresh()

        #expect(try await pollUntil {
            await pairedMacStore.currentLoadStartCount(teamID: "team-c") == 1
        })
        #expect(await pairedMacStore.currentLoadStartCount(teamID: "team-b") == 0)
        #expect(try await pollUntil {
            store.connectionLifecycle.resourceSnapshot.activeEpisodeCount == 0
                && store.connectionLifecycle.resourceSnapshot.pendingRequestCount == 0
        })
    }

    @Test func manualPairingClearsReconnectReplayQueuedBehindRetiredTask() async throws {
        let team = MutableTeamID("team-a")
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [:],
            blockedTeams: ["team-a"]
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { await team.value }
        )
        let oldReconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitUntilLoadStarted(teamID: "team-a")

        await team.set("team-b")
        store.currentTeamDidChange()
        store.prepareForManualPairing()
        await team.set("team-c")
        store.currentTeamDidChange()
        await pairedMacStore.release(teamID: "team-a")

        #expect(await oldReconnect.value == false)
        #expect(try await pollUntil {
            store.connectionResourceSnapshotForTesting().retiredLifecycleTaskCount == 0
        })
        #expect(await pairedMacStore.currentLoadStartCount(teamID: "team-b") == 0)
        #expect(await pairedMacStore.currentLoadStartCount(teamID: "team-c") == 0)
        #expect(store.connectionLifecycle.activeEpisode == nil)
    }

    @Test func directPairingURLSupersedesOwnedStoredMacReconnect() async throws {
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [:],
            blockedTeams: [""]
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        let result = ReconnectResultProbe()
        let reconnect = Task { @MainActor in
            let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
            await result.record(connected)
            return connected
        }
        await pairedMacStore.waitUntilLoadStarted(teamID: nil)

        #expect(await store.connectPairingURLResult("invalid-pairing-url") == .failed)
        #expect(try await pollUntil { await result.value() == false })
        #expect(store.connectionLifecycleRequestWaiters.isEmpty)
        #expect(store.connectionLifecycle.activeEpisode == nil)

        store.prepareForManualPairing()
        await pairedMacStore.release(teamID: nil)
        #expect(await reconnect.value == false)
    }

    @Test func manualPairingClearsStoredReconnectTimeoutCopy() {
        let store = MobileShellComposite.preview()
        store.applyStoredMacReconnectDeadlineFailure()

        store.prepareForManualPairing()

        #expect(store.connectionError == nil)
        #expect(store.connectionErrorGuidance == nil)
    }

    @Test func manualPairingClearsInactiveQueuedStoredMacReconnect() async throws {
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [:],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        store.suspendForegroundRefresh()
        let result = ReconnectResultProbe()
        let reconnect = Task { @MainActor in
            let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
            await result.record(connected)
            return connected
        }
        #expect(try await pollUntil {
            store.connectionLifecycle.resourceSnapshot.pendingRequestCount == 1
                && store.connectionLifecycleRequestWaiters.count == 1
        })

        store.prepareForManualPairing()

        #expect(try await pollUntil { await result.value() == false })
        #expect(store.connectionLifecycle.resourceSnapshot.pendingRequestCount == 0)
        #expect(store.connectionLifecycleRequestWaiters.isEmpty)
        store.resetConnectionLifecycle()
        #expect(await reconnect.value == false)
        store.resumeForegroundRefresh()
        #expect(await pairedMacStore.currentLoadStartCount(teamID: nil) == 0)
    }

    @Test func emptyPairedMacStoreCompletesWithoutRecoveryFailure() async {
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: DelayedTeamPairedMacStore(
                recordsByTeam: [:],
                blockedTeams: []
            ),
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )

        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(!connected)
        #expect(!store.connectionRecoveryFailed)
        #expect(store.connectionError == nil)
        #expect(store.connectionErrorGuidance == nil)
        #expect(store.didFinishStoredMacReconnectAttempt)
    }
}

private func storedMac(
    id: String,
    route: CmxAttachRoute,
    isActive: Bool
) -> MobilePairedMac {
    MobilePairedMac(
        macDeviceID: id,
        displayName: "Test Mac",
        routes: [route],
        createdAt: Date(),
        lastSeenAt: Date(),
        isActive: isActive,
        stackUserID: "user-1"
    )
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
