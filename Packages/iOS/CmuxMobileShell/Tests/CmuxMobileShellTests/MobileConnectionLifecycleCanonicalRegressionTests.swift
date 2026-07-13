import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
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
        await pairedMacStore.release(teamID: nil)
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
        let boundedResources = store.connectionResourceSnapshotForTesting()
        #expect(boundedResources.activeEpisodeCount == 0)
        #expect(boundedResources.retiredLifecycleTaskCount == 1)
        #expect(boundedResources.retiredCachedLifecycleTaskCount == 1)

        store.retryMobileConnection()
        let accumulatedAnotherAttempt = try await pollUntil(attempts: 50) {
            factory.attemptedPorts().count > 1
        }
        #expect(!accumulatedAnotherAttempt)

        factory.releaseHeldConnect()
        await pairedMacStore.release(teamID: nil)
        #expect(try await pollUntil {
            store.connectionResourceSnapshotForTesting().retiredLifecycleTaskCount == 0
                && store.connectionResourceSnapshotForTesting().retiredCachedLifecycleTaskCount == 0
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

        #expect(try await pollUntil {
            await pairedMacStore.currentLoadStartCount(teamID: nil) == 3
        })
        store.signOut()
        await pairedMacStore.release(teamID: nil)
        #expect(await reconnect.value == false)
        #expect(await switched.value == false)
    }

    @Test func eventStreamLossDoesNotRefreshStoredSecondaryMacs() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let route = try loopbackRoute(id: "foreground", port: 51_002)
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { clock.now }
        )
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [storedMac(id: "mac-b", route: route)]],
            blockedTeams: []
        )
        let defaults = UserDefaults(suiteName: "stream-repair-scope-\(UUID().uuidString)")!
        defaults.set(true, forKey: "multiMacAggregation")
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            multiMacAggregationDefaults: defaults
        )
        let ticket = try makeTicket(clock: clock)
        let foregroundRoute = try #require(ticket.routes.first)
        store.activeTicket = ticket
        store.activeRoute = foregroundRoute
        store.foregroundMacDeviceID = ticket.macDeviceID
        store.remoteClient = MobileCoreRPCClient(
            runtime: runtime,
            route: foregroundRoute,
            ticket: ticket,
            allowsStackAuthFallback: true
        )

        store.requestConnectionLifecycleRecovery(.eventStreamLost)

        let refreshedSecondaries = try await pollUntil(attempts: 50) {
            await pairedMacStore.currentLoadAllCount() > 0
        }
        #expect(!refreshedSecondaries)
        store.signOut()
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
