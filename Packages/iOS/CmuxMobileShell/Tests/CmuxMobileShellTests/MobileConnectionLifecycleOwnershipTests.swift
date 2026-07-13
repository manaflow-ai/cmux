import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileConnectionLifecycleOwnershipTests {
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

    @Test func retriesDoNotStartMoreStoreReadsWhileCanceledWorkIsStillBlocked() async throws {
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
        let replayedStoreRead = try await pollUntil(attempts: 50) {
            await pairedMacStore.currentLoadStartCount(teamID: nil) > 1
        }
        #expect(!replayedStoreRead)
        #expect(try await pollUntil {
            store.connectionResourceSnapshotForTesting().retiredLifecycleTaskCount == 0
                && store.connectionLifecycle.activeEpisode == nil
        })
        let resources = store.connectionResourceSnapshotForTesting()
        #expect(resources.activeEpisodeCount == 0)
        #expect(resources.pendingRequestCount == 0)
        #expect(resources.lifecycleTaskCount == 0)
        #expect(resources.retiredLifecycleTaskCount == 0)
        #expect(resources.lifecycleWaiterCount == 0)
    }

    @Test func rejectedReconnectResolvesCallerWithoutLeakingWaiter() async throws {
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [:],
            blockedTeams: [""]
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        let first = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitUntilLoadStarted(teamID: nil)
        defer { Task { await pairedMacStore.release(teamID: nil) } }

        store.retryMobileConnection()
        let result = ReconnectResultProbe()
        let rejected = Task { @MainActor in
            let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
            await result.record(connected)
            return connected
        }

        #expect(try await pollUntil { await result.value() == false })
        #expect(store.connectionLifecycleRequestWaiters.isEmpty)
        #expect(store.connectionLifecycle.resourceSnapshot.pendingRequestCount == 0)

        for continuation in store.connectionLifecycleRequestWaiters.values {
            continuation.resume()
        }
        store.connectionLifecycleRequestWaiters.removeAll()
        await pairedMacStore.release(teamID: nil)
        store.signOut()
        #expect(await first.value == false)
        #expect(await rejected.value == false)
    }

    @Test func manualPairingSupersedesReconnectAlreadyPersistingItsTicket() async throws {
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
                "": [storedReconnectMac(route: route)],
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
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitUntilUpsertStarted(macDeviceID: "test-mac")

        store.prepareForManualPairing()
        await pairedMacStore.releaseUpsert(macDeviceID: "test-mac")

        #expect(await reconnect.value == false)
        #expect(try await pollUntil {
            store.connectionResourceSnapshotForTesting().retiredLifecycleTaskCount == 0
        })
        #expect(store.connectionError == nil)
        #expect(store.connectionErrorGuidance == nil)
        #expect(store.connectionState == .disconnected)
    }

    @Test func manualHostSubmissionSupersedesReconnectStartedWhileSheetWasOpen() async throws {
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
                "": [storedReconnectMac(route: route)],
            ],
            blockedTeams: [""]
        )
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(router: router, box: box),
                now: { clock.now }
            ),
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

        let manualPairing = Task { @MainActor in
            await store.connectManualHost(
                name: "New Mac",
                host: "127.0.0.1",
                port: 56_584
            )
        }
        let superseded = try await pollUntil { await result.value() == false }
        #expect(superseded)
        #expect(try await pollUntil {
            await pairedMacStore.currentLoadStartCount(teamID: nil) == 2
        })

        await pairedMacStore.release(teamID: nil)
        await manualPairing.value
        #expect(await reconnect.value == false)
    }

    @Test func retryWithoutCachedMacReplaysAfterRetirement() async throws {
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

        store.retryMobileConnection()
        #expect(try await pollUntil {
            store.connectionLifecycle.activeEpisode == nil
        })
        #expect(store.connectionRecoveryFailed)
        #expect(store.hasStoredMacReconnectDemand)
        await pairedMacStore.release(teamID: nil)

        let replayed = try await pollUntil(attempts: 50) {
            await pairedMacStore.currentLoadStartCount(teamID: nil) > 1
        }
        #expect(replayed)
        await pairedMacStore.release(teamID: nil)
        #expect(await reconnect.value == false)
        #expect(try await pollUntil {
            store.connectionResourceSnapshotForTesting().retiredLifecycleTaskCount == 0
                && store.connectionLifecycle.activeEpisode == nil
        })
    }

    @Test func forgettingReconnectTargetRemovesMismatchedTicketWrite() async throws {
        let router = LivenessHostRouter()
        await router.setAttachTicketMacDeviceID("mac-b")
        await router.setHostIdentity(deviceID: "mac-a", instanceTag: "default")
        let box = TransportBox()
        let clock = TestClock()
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "": [storedReconnectMac(id: "mac-a", route: route)],
            ],
            blockedTeams: []
        )
        await pairedMacStore.gateUpsert(macDeviceID: "mac-b")
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(router: router, box: box),
                now: { clock.now }
            ),
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitUntilUpsertStarted(macDeviceID: "mac-b")
        #expect(store.connectionLifecycle.activeEpisode?.kind == .reconnect)
        #expect(store.storedMacReconnectTargetDeviceID == "mac-a")
        let generationBeforeForget = store.storedMacReconnectGeneration

        await store.forgetStoredMac(macDeviceID: "mac-a")
        #expect(store.storedMacReconnectGeneration > generationBeforeForget)
        await pairedMacStore.releaseUpsert(macDeviceID: "mac-b")

        #expect(await reconnect.value == false)
        #expect(try await pollUntil {
            store.connectionResourceSnapshotForTesting().retiredLifecycleTaskCount == 0
        })
        let remaining = try await pairedMacStore.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(remaining.isEmpty)
    }

    @Test func mismatchedTicketRollbackPreservesPreviouslySavedDestination() async throws {
        let router = LivenessHostRouter()
        await router.setAttachTicketMacDeviceID("mac-b")
        await router.setHostIdentity(deviceID: "mac-a", instanceTag: "default")
        let box = TransportBox()
        let clock = TestClock()
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let savedDestinationRoute = try CmxAttachRoute(
            id: "saved_tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.210.41", port: 50_922)
        )
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "": [
                    storedReconnectMac(id: "mac-a", route: route),
                    storedReconnectMac(
                        id: "mac-b",
                        displayName: "Saved B",
                        route: savedDestinationRoute,
                        isActive: false
                    ),
                ],
            ],
            blockedTeams: []
        )
        await pairedMacStore.gateUpsert(macDeviceID: "mac-b")
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(router: router, box: box),
                now: { clock.now }
            ),
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitUntilUpsertStarted(macDeviceID: "mac-b")
        #expect(store.connectionLifecycle.activeEpisode?.kind == .reconnect)
        #expect(store.storedMacReconnectTargetDeviceID == "mac-a")
        let generationBeforeForget = store.storedMacReconnectGeneration

        await store.forgetStoredMac(macDeviceID: "mac-a")
        #expect(store.storedMacReconnectGeneration > generationBeforeForget)
        await pairedMacStore.releaseUpsert(macDeviceID: "mac-b")

        #expect(await reconnect.value == false)
        #expect(try await pollUntil {
            store.connectionResourceSnapshotForTesting().retiredLifecycleTaskCount == 0
        })
        let remaining = try await pairedMacStore.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(remaining.count == 1)
        #expect(remaining.first?.macDeviceID == "mac-b")
        #expect(remaining.first?.displayName == "Saved B")
        #expect(remaining.first?.isActive == false)
    }
}

private func storedReconnectMac(
    id: String = "test-mac",
    displayName: String = "Test Mac",
    route: CmxAttachRoute,
    isActive: Bool = true
) -> MobilePairedMac {
    MobilePairedMac(
        macDeviceID: id,
        displayName: displayName,
        routes: [route],
        createdAt: Date(),
        lastSeenAt: Date(),
        isActive: isActive,
        stackUserID: "user-1"
    )
}
