import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileConnectionLifecycleDeferredPersistenceRegressionTests {
    @Test func deferredCachedPersistenceCannotOverwriteLaterManualPairing() async throws {
        let deadline = ControlledStoredMacReconnectDeadline()
        let route = try loopbackRoute(id: "deferred-persistence", port: 51_010)
        let router = LivenessHostRouter()
        await router.setAttachTicketMacDeviceID("mac-a")
        await router.setHostIdentity(deviceID: "mac-a", instanceTag: "default")
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [storedMac(id: "mac-a", route: route)]],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() },
                supportedRouteKinds: [.debugLoopback]
            ),
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            storedMacReconnectDeadline: { await deadline.wait() }
        )
        await store.loadPairedMacs()
        await pairedMacStore.blockLoads(teamID: nil)
        let primaryReconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        #expect(try await pollUntil {
            await pairedMacStore.currentLoadStartCount(teamID: nil) == 2
        })
        await deadline.waitUntilArmed()
        await deadline.expire()
        #expect(await primaryReconnect.value == false)

        store.retryMobileConnection()
        #expect(try await pollUntil {
            store.connectionState == .connected
                && store.foregroundMacDeviceID == "mac-a"
                && store.connectionLifecycleTaskOwnership.pendingCachedReconnectPersistence != nil
        })

        // Keep only the already-retired primary read blocked. The user's later
        // pairing must be able to persist its own selection before that read returns.
        await pairedMacStore.unblockLoads(teamID: nil)
        await router.setAttachTicketMacDeviceID("mac-b")
        await router.setHostIdentity(deviceID: "mac-b", instanceTag: "default")
        await store.connectManualHost(
            name: "Mac B",
            host: "127.0.0.1",
            port: 51_010,
            pairedMacDeviceID: "mac-b"
        )
        #expect(store.connectionState == .connected)
        #expect(store.foregroundMacDeviceID == "mac-b")
        #expect(
            try await pairedMacStore.activeMac(
                stackUserID: "user-1",
                teamID: nil
            )?.macDeviceID == "mac-b"
        )
        await pairedMacStore.release(teamID: nil)
        let staleMacAWriteRan = try await pollUntil(attempts: 50) {
            await pairedMacStore.currentUpsertedMacDeviceIDs().contains("mac-a")
        }
        #expect(!staleMacAWriteRan)
        #expect(
            try await pairedMacStore.activeMac(
                stackUserID: "user-1",
                teamID: nil
            )?.macDeviceID == "mac-b"
        )
    }

    @Test func blockedDeferredPersistenceRemainsOwnedUntilShellTeardown() async throws {
        let deadline = ControlledStoredMacReconnectDeadline()
        let route = try loopbackRoute(id: "blocked-persistence", port: 51_011)
        let router = LivenessHostRouter()
        await router.setAttachTicketMacDeviceID("mac-a")
        await router.setHostIdentity(deviceID: "mac-a", instanceTag: "default")
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [storedMac(id: "mac-a", route: route)]],
            blockedTeams: []
        )
        var store: MobileShellComposite? = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() },
                supportedRouteKinds: [.debugLoopback]
            ),
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            storedMacReconnectDeadline: { await deadline.wait() }
        )
        weak let weakStore = store
        await store?.loadPairedMacs()
        await pairedMacStore.blockLoads(teamID: nil)
        store?.requestConnectionLifecycleRecovery(.manualRetry)
        #expect(try await pollUntil {
            await pairedMacStore.currentLoadStartCount(teamID: nil) == 2
        })
        await deadline.waitUntilArmed()
        await deadline.expire()

        store?.retryMobileConnection()
        #expect(try await pollUntil {
            store?.connectionState == .connected
                && store?.connectionLifecycleTaskOwnership.pendingCachedReconnectPersistence != nil
        })

        await pairedMacStore.unblockLoads(teamID: nil)
        await pairedMacStore.gateUpsert(macDeviceID: "mac-a")
        defer {
            Task { await pairedMacStore.releaseUpsert(macDeviceID: "mac-a") }
        }
        await pairedMacStore.release(teamID: nil)
        await pairedMacStore.waitUntilUpsertStarted(macDeviceID: "mac-a")

        // Teardown must still be able to find and cancel the task while the
        // cancellation-insensitive store write is suspended.
        store?.signOut()
        store = nil

        #expect(try await pollUntil(attempts: 50) { weakStore == nil })
    }

    private func loopbackRoute(id: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port)
        )
    }

    private func storedMac(
        id: String,
        route: CmxAttachRoute,
        isActive: Bool = true
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: id,
            routes: [route],
            createdAt: Date(),
            lastSeenAt: Date(),
            isActive: isActive,
            stackUserID: "user-1"
        )
    }
}
