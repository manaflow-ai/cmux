import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileConnectionLifecycleTests {
    @Test func staleListenerHealthCannotCompleteRepairBeforeReplacementStarts() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1)
        let baselineSubscriptions = await router.count(of: "mobile.events.subscribe")

        store.requestConnectionLifecycleRecovery(.eventStreamLost)
        store.markMacConnectionHealthy()

        await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: baselineSubscriptions + 1
        )
        #expect(await router.count(of: "mobile.events.subscribe") == baselineSubscriptions + 1)
    }

    @Test func backgroundPathChangesCoalesceUntilOneForegroundRecovery() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let reachability = ControllableReachability()
        let store = try await makeLifecycleConnectedStore(
            router: router,
            box: box,
            clock: clock,
            reachability: reachability
        )

        store.resumeForegroundRefresh()
        await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1)
        let baselineSubscriptions = await router.count(of: "mobile.events.subscribe")

        store.suspendForegroundRefresh()
        for _ in 0..<20 {
            reachability.sendPathChange()
        }

        let backgroundRestarted = await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: baselineSubscriptions + 1,
            timeoutNanoseconds: 200_000_000,
            recordIssueOnTimeout: false
        )
        #expect(!backgroundRestarted)

        clock.advance(by: 31)
        store.resumeForegroundRefresh()
        await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: baselineSubscriptions + 1
        )
        #expect(await router.count(of: "mobile.events.subscribe") == baselineSubscriptions + 1)
    }

    @Test func repeatedInactiveTransitionsDoNotCreateExtraRecoveryEpisodes() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1)
        let baselineSubscriptions = await router.count(of: "mobile.events.subscribe")

        for _ in 0..<200 {
            store.suspendForegroundRefresh()
        }
        clock.advance(by: 31)
        store.resumeForegroundRefresh()

        await router.waitForCount(of: "mobile.events.subscribe", atLeast: baselineSubscriptions + 1)
        #expect(await router.count(of: "mobile.events.subscribe") == baselineSubscriptions + 1)
    }

    @Test func eventStreamLossRefreshesTheAuthoritativeWorkspaceList() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        let baselineWorkspaceLists = await router.count(of: "mobile.workspace.list")
            + router.count(of: "workspace.list")

        store.requestConnectionLifecycleRecovery(.eventStreamLost)

        let refreshed = try await pollUntil {
            let current = await router.count(of: "mobile.workspace.list")
                + router.count(of: "workspace.list")
            return current > baselineWorkspaceLists
        }
        #expect(refreshed)
    }

    @Test func connectionTeardownCompletesAnUnacknowledgedStreamRepair() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        let baselineSubscriptions = await router.count(of: "mobile.events.subscribe")
        await router.setHoldSubscribe(true)
        defer { Task { await router.releaseAllHeld() } }

        store.requestConnectionLifecycleRecovery(.eventStreamLost)
        await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: baselineSubscriptions + 1
        )
        #expect(store.connectionLifecycle.activeEpisode?.kind == .streamRepair)

        store.disconnectLiveConnection()

        #expect(store.connectionLifecycle.activeEpisode == nil)
    }

    @Test func connectionTeardownDropsRecoveryQueuedBehindStreamRepair() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        let baselineSubscriptions = await router.count(of: "mobile.events.subscribe")
        await router.setHoldSubscribe(true)
        defer { Task { await router.releaseAllHeld() } }

        store.requestConnectionLifecycleRecovery(.eventStreamLost)
        await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: baselineSubscriptions + 1
        )
        #expect(store.connectionLifecycle.activeEpisode?.kind == .streamRepair)

        _ = store.connectionLifecycle.requestStoredMacReconnect(
            stackUserID: "next-user",
            health: MobileConnectionLifecycleHealthSnapshot(
                connected: false,
                hasClient: false,
                hasListener: false,
                eventStreamFresh: false,
                canReconnectPersistedMac: true
            )
        )

        store.disconnectLiveConnection()

        #expect(store.connectionLifecycle.activeEpisode == nil)
    }

    @Test func resettingStreamRepairReconcilesSurvivingLiveConnectionStatus() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        let baselineSubscriptions = await router.count(of: "mobile.events.subscribe")
        await router.setHoldSubscribe(true)
        defer { Task { await router.releaseAllHeld() } }

        store.requestConnectionLifecycleRecovery(.eventStreamLost)
        await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: baselineSubscriptions + 1
        )
        #expect(store.macConnectionStatus == .reconnecting)

        store.resetConnectionLifecycle()

        #expect(store.connectionLifecycle.activeEpisode == nil)
        #expect(store.connectionState == .connected)
        #expect(store.macConnectionStatus == .connected)
    }

    @Test func replayOnlyRuntimeCompletesStreamRepairWithoutPushListener() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now },
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        let connected = await store.connectPairingURL(
            try attachURL(for: makeTicket(clock: clock))
        )
        #expect(connected)
        #expect(store.terminalEventListenerTask == nil)

        store.requestConnectionLifecycleRecovery(.eventStreamLost)
        await Task.yield()

        #expect(store.connectionLifecycle.activeEpisode == nil)
        #expect(!store.connectionRecoveryFailed)
        #expect(store.macConnectionStatus == .connected)
    }
}

@MainActor
private func makeLifecycleConnectedStore(
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock,
    reachability: ControllableReachability
) async throws -> MobileShellComposite {
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now }
    )
    let store = MobileShellComposite(
        runtime: runtime,
        reachability: reachability,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer()
    )
    store.signIn()
    let connected = await store.connectPairingURL(try attachURL(for: makeTicket(clock: clock)))
    #expect(connected, "scripted connect must succeed")
    return store
}
