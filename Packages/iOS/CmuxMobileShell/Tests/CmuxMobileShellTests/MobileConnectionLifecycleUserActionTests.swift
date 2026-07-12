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

    @Test func ownedDeadlineResolvesReconnectBlockedInStoreIO() async {
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

        await deadline.expire()

        #expect(await reconnect.value == false)
        #expect(store.connectionRecoveryFailed)
        #expect(store.connectionError == "Still loading")
        #expect(store.connectionErrorGuidance == "cmux could not finish restoring this session. Check that the selected cmux build is running, then retry or add this computer again.")
        #expect(store.connectionLifecycle.activeEpisode == nil)
        #expect(store.connectionLifecycle.resourceSnapshot.pendingRequestCount == 0)
        #expect(store.connectionLifecycleRequestWaiters.isEmpty)
        #expect(store.connectionLifecycleTask == nil)
        #expect(store.connectionLifecycleDeadlineTask == nil)
        #expect(store.didFinishStoredMacReconnectAttempt)
    }

    @Test func retriesDoNotStartMoreReconnectsWhileCanceledWorkIsStillBlocked() async throws {
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

        for _ in 0..<20 {
            store.retryMobileConnection()
            await Task.yield()
        }

        let startedDuplicate = try await pollUntil(attempts: 50) {
            await pairedMacStore.currentLoadStartCount(teamID: nil) > 1
        }
        #expect(!startedDuplicate)
        await pairedMacStore.release(teamID: nil)
        _ = await reconnect.value
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

private actor ControlledStoredMacReconnectDeadline {
    private var isArmed = false
    private var armWaiters: [CheckedContinuation<Void, Never>] = []
    private var deadlineWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        isArmed = true
        let waiters = armWaiters
        armWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            deadlineWaiter = continuation
        }
    }

    func waitUntilArmed() async {
        if isArmed { return }
        await withCheckedContinuation { continuation in
            armWaiters.append(continuation)
        }
    }

    func expire() async {
        deadlineWaiter?.resume()
        deadlineWaiter = nil
        await Task.yield()
        await Task.yield()
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
