import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileConnectionLifecycleCanonicalRegressionTests {
    @Test func automaticTriggerWaitsForRetiredReconnectThenReplays() async throws {
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
        await deadline.expire()
        #expect(await reconnect.value == false)
        #expect(store.connectionRecoveryFailed)

        store.requestConnectionLifecycleRecovery(.networkPathChanged)

        #expect(store.connectionRecoveryFailed)
        #expect(store.hasStoredMacReconnectDemand)
        await pairedMacStore.release(teamID: nil)
        #expect(try await pollUntil {
            await pairedMacStore.currentLoadStartCount(teamID: nil) == 2
        })
        #expect(try await pollUntil {
            store.connectionResourceSnapshotForTesting().retiredLifecycleTaskCount == 0
                && store.connectionLifecycle.activeEpisode == nil
        })
    }

    @Test func cachedRetryArmsOverallDeadlineWhilePrimaryStoreReadIsRetired() async throws {
        let deadline = ControlledStoredMacReconnectDeadline()
        let route = try loopbackRoute(id: "held", port: 51_000)
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [storedMac(id: "mac-a", route: route)]],
            blockedTeams: []
        )
        let factory = RouteRecordingTransportFactory(
            router: LivenessHostRouter(),
            box: TransportBox(),
            failingPorts: [51_000],
            holdFirstFailingPort: 51_000
        )
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
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
        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        #expect(try await pollUntil {
            await pairedMacStore.currentLoadStartCount(teamID: nil) == 2
        })
        await deadline.waitUntilArmed()
        await deadline.expire()
        #expect(await reconnect.value == false)

        store.retryMobileConnection()
        #expect(try await pollUntil { factory.attemptedPorts() == [51_000] })
        let cachedDeadlineArmed = try await pollUntil(attempts: 50) {
            await deadline.currentArmCount() == 2
        }
        #expect(cachedDeadlineArmed)

        if cachedDeadlineArmed {
            await deadline.expire()
        }
        factory.releaseHeldConnect()
        await pairedMacStore.release(teamID: nil)
        #expect(try await pollUntil {
            store.connectionResourceSnapshotForTesting().retiredLifecycleTaskCount == 0
                && store.connectionLifecycle.activeEpisode == nil
        })
    }

    @Test func interactiveMacSwitchSupersedesSuspendedAutomaticReconnect() async throws {
        let route = try loopbackRoute(id: "debug", port: 51_001)
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "": [
                    storedMac(id: "mac-a", route: route, isActive: true),
                    storedMac(id: "mac-b", route: route, isActive: false),
                ],
            ],
            blockedTeams: []
        )
        let router = LivenessHostRouter()
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
                now: { Date() },
                supportedRouteKinds: [.debugLoopback]
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
        let reconnectGeneration = store.storedMacReconnectGeneration
        await router.setAttachTicketMacDeviceID("mac-b")
        await router.setHostIdentity(deviceID: "mac-b", instanceTag: "default")

        let switched = Task { @MainActor in
            await store.switchToMac(macDeviceID: "mac-b")
        }
        let supersededBeforeStoreReturned = try await pollUntil(attempts: 50) {
            store.storedMacReconnectGeneration > reconnectGeneration
                && store.connectionLifecycle.activeEpisode == nil
        }
        #expect(supersededBeforeStoreReturned)

        if !supersededBeforeStoreReturned {
            store.signOut()
        }
        await pairedMacStore.release(teamID: nil)
        #expect(await reconnect.value == false)
        let didSwitch = await switched.value
        if supersededBeforeStoreReturned {
            #expect(didSwitch)
            #expect(store.foregroundMacDeviceID == "mac-b")
        }
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
