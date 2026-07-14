import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileConnectionLifecycleRaceRegressionTests {
    @Test func retryUsesCachedMacWhileRetiredStoreReadNeverReturns() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let route = try reconnectRoute()
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [storedMac(id: "test-mac", route: route)]],
            blockedTeams: []
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
        await store.loadPairedMacs()
        await pairedMacStore.blockLoads(teamID: nil)
        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        #expect(try await pollUntil {
            await pairedMacStore.currentLoadStartCount(teamID: nil) == 2
        })

        store.retryMobileConnection()

        #expect(try await pollUntil { store.connectionState == .connected })
        let loadStartCount = await pairedMacStore.currentLoadStartCount(teamID: nil)
        #expect(loadStartCount == 2)
        #expect(store.connectionLifecycle.activeEpisode == nil)
        #expect(await reconnect.value == false)
        await pairedMacStore.release(teamID: nil)
    }

    @Test func forgetIntentIsVisibleBeforeDurableTombstoneLoadReturns() async throws {
        let forgottenStore = BlockingForgottenMacStore()
        let store = MobileShellComposite(forgottenMacStore: forgottenStore)
        let remember = Task { @MainActor in
            await store.rememberForgottenMacDeviceID("mac-a", scopeKey: "scope-a")
        }
        await forgottenStore.waitUntilLoadStarted()

        #expect(store.forgottenMacIntentDeviceIDsByScope["scope-a"] == ["mac-a"])

        await forgottenStore.releaseLoads()
        await remember.value
    }

    @Test func explicitReconnectClearWinsAgainstSuspendedTombstoneLoad() async throws {
        let forgottenStore = BlockingForgottenMacStore()
        let store = MobileShellComposite(forgottenMacStore: forgottenStore)
        let remember = Task { @MainActor in
            await store.rememberForgottenMacDeviceID("mac-a", scopeKey: "scope-a")
        }
        await forgottenStore.waitUntilLoadStarted()

        let clear = Task { @MainActor in
            await store.clearForgottenMacDeviceID("mac-a", scopeKey: "scope-a")
        }
        #expect(try await pollUntil {
            store.forgottenMacIntentDeviceIDsByScope["scope-a"]?.contains("mac-a") != true
        })
        await forgottenStore.releaseLoads()
        await clear.value
        await remember.value

        #expect(await store.storedForgottenMacDeviceIDs(scopeKey: "scope-a").isEmpty)
        #expect(await forgottenStore.ids(scope: "scope-a").isEmpty)
    }

    @Test func compactTicketRollbackDoesNotRestoreAnotherTeamScope() async throws {
        let route = try reconnectRoute()
        let currentMac = storedMac(id: "mac-a", route: route, teamID: "team-a")
        let legacyDestination = MobilePairedMac(
            macDeviceID: "mac-b",
            displayName: "Legacy B",
            routes: [route],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: false,
            stackUserID: nil,
            teamID: nil
        )
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [currentMac],
                "": [legacyDestination],
            ],
            blockedTeams: []
        )
        await pairedMacStore.gateUpsert(macDeviceID: "mac-b")
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        let scope = MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0)
        await store.rememberForgottenMacDeviceID("mac-a", scope: scope)
        var ownsPersistence = true
        let persist = Task { @MainActor in
            await store.persistPairedMacFromTicket(
                try compactTicket(macDeviceID: "mac-b", route: route),
                clearsForgottenMac: false,
                reconnectSourceMacDeviceID: "mac-a",
                ifStillCurrent: { ownsPersistence }
            )
        }
        await pairedMacStore.waitUntilUpsertStarted(macDeviceID: "mac-b")

        ownsPersistence = false
        await pairedMacStore.releaseUpsert(macDeviceID: "mac-b")
        _ = try await persist.value

        let visible = try await pairedMacStore.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        ).filter { $0.macDeviceID == "mac-b" }
        #expect(visible.count == 1)
        #expect(visible.first?.teamID == nil)
        #expect(visible.first?.displayName == "Legacy B")
    }

    @Test func staleReconnectRollbackCannotOverwriteNewerActiveWrite() async throws {
        let route = try reconnectRoute()
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "": [
                    storedMac(id: "mac-a", route: route),
                    storedMac(id: "mac-b", route: route, isActive: false),
                ],
            ],
            blockedTeams: []
        )
        await pairedMacStore.gateUpsert(macDeviceID: "mac-b")
        let router = LivenessHostRouter()
        await router.setAttachTicketMacDeviceID("mac-b")
        await router.setHostIdentity(deviceID: "mac-b", instanceTag: "default")
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitUntilUpsertStarted(macDeviceID: "mac-b")

        store.prepareForManualPairing()
        let newerWrite = Task { @MainActor in
            await store.persistPairedMacFromTicket(
                try compactTicket(macDeviceID: "mac-c", route: route)
            )
        }
        _ = try await pollUntil(attempts: 50) {
            await pairedMacStore.currentUpsertCount() == 1
        }
        await pairedMacStore.releaseUpsert(macDeviceID: "mac-b")

        #expect(await reconnect.value == false)
        #expect(try await newerWrite.value)
        #expect(try await pollUntil {
            store.connectionResourceSnapshotForTesting().retiredLifecycleTaskCount == 0
        })
        let active = try await pairedMacStore.activeMac(
            stackUserID: "user-1",
            teamID: nil
        )
        #expect(active?.macDeviceID == "mac-c")
    }

    @Test func preservingLegacyAuthorityMigratesItsInstanceTagIntoTeamScope() async throws {
        let route = try reconnectRoute()
        var legacy = storedMac(id: "mac-b", route: route)
        legacy.instanceTag = "feature-a"
        legacy.teamID = nil
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [legacy]],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )

        let accepted = await store.persistPairedMacFromTicket(
            try compactTicket(macDeviceID: "mac-b", route: route),
            instanceTagUpdate: .preserve
        )

        #expect(accepted)
        let migrated = try await pairedMacStore.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        ).first { $0.teamID == "team-a" && $0.macDeviceID == "mac-b" }
        #expect(migrated?.instanceTag == "feature-a")
    }

    private func reconnectRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
    }

    private func storedMac(
        id: String,
        route: CmxAttachRoute,
        teamID: String? = nil,
        isActive: Bool = true
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: "Test Mac",
            routes: [route],
            createdAt: Date(),
            lastSeenAt: Date(),
            isActive: isActive,
            stackUserID: "user-1",
            teamID: teamID
        )
    }

    private func compactTicket(
        macDeviceID: String,
        route: CmxAttachRoute
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: macDeviceID,
            macDisplayName: nil,
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
    }
}
