import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func shortHealthyForegroundResumeDoesNotReplayMountedSurfaces() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    try await waitForReplayResponsesServed(
        1,
        store: store,
        router: router,
        "the cold replay response must settle before testing foreground resume"
    )
    let replayCount = await router.count(of: "mobile.terminal.replay")
    let subscribeCount = await router.count(of: "mobile.events.subscribe")

    store.suspendForegroundRefresh()
    clock.advance(by: 5)
    store.resumeForegroundRefresh()

    let replayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCount + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!replayRequested)
    let resubscribed = await router.waitForCount(
        of: "mobile.events.subscribe",
        atLeast: subscribeCount + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!resubscribed)
    collector.unmount()
}

@MainActor
@Test func longForegroundResumeStillReplaysMountedSurfaces() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    try await waitForReplayResponsesServed(
        1,
        store: store,
        router: router,
        "the cold replay response must settle before testing long foreground resume"
    )
    let subscribeCount = await router.count(of: "mobile.events.subscribe")

    store.suspendForegroundRefresh()
    clock.advance(by: 31)
    store.resumeForegroundRefresh()

    await router.waitForCount(of: "mobile.events.subscribe", atLeast: subscribeCount + 1)
    collector.unmount()
}

@MainActor
@Test func inactiveReturnDoesNotResetLongBackgroundDwell() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    try await waitForReplayResponsesServed(
        1,
        store: store,
        router: router,
        "the cold replay response must settle before testing foreground phase order"
    )
    let subscribeCount = await router.count(of: "mobile.events.subscribe")

    store.suspendForegroundRefresh()
    clock.advance(by: 31)
    store.suspendForegroundRefresh()
    store.resumeForegroundRefresh()

    await router.waitForCount(of: "mobile.events.subscribe", atLeast: subscribeCount + 1)
    collector.unmount()
}

@Suite(.serialized)
struct MobileShellForegroundConnectionRecoveryTests {
@MainActor
@Test func foregroundProbeKeepsHealthyConnectionVisiblyConnected() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let (store, directory) = try await makeForegroundRecoveryStore(
        router: router,
        box: box,
        clock: clock
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
    await router.holdNextWorkspaceListRequests()
    let probeCount = await router.count(of: "mobile.workspace.list")

    store.resumeForegroundRefresh()

    #expect(await router.waitForCount(
        of: "mobile.workspace.list",
        atLeast: probeCount + 1
    ))
    #expect(store.macConnectionStatus == .connected)
    #expect(!store.isRecoveringConnection)

    await router.releaseAllHeld()
    #expect(try await pollUntil {
        store.connectionRecoveryOwner.phase == .idle
    })
    #expect(store.connectionState == .connected)
    #expect(try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    })
}

@MainActor
@Test func failedForegroundProbeWithLiveTransportDoesNotRedial() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let (store, directory) = try await makeForegroundRecoveryStore(
        router: router,
        box: box,
        clock: clock,
        probeTimeoutNanoseconds: 50_000_000
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
    await router.holdNextWorkspaceListRequests(count: 2)

    store.resumeForegroundRefresh()

    #expect(try await pollUntil {
        store.connectionRecoveryOwner.phase == .idle
            && !store.isRecoveringConnection
            && store.connectionState == .connected
    })
    await router.releaseAllHeld()
}

@MainActor
@Test func foregroundProbeTimeoutWithLiveTransportRepairsMountedTerminal() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let (store, directory) = try await makeForegroundRecoveryStore(
        router: router,
        box: box,
        clock: clock,
        probeTimeoutNanoseconds: 50_000_000
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    try await waitForReplayResponsesServed(
        1,
        store: store,
        router: router,
        "the cold replay response must settle before testing a foreground probe timeout"
    )
    let replayCount = await router.count(of: "mobile.terminal.replay")
    let originalTransport = try #require(box.get())

    store.suspendForegroundRefresh()
    clock.advance(by: 31)
    await router.holdNextWorkspaceListRequests()
    store.resumeForegroundRefresh()
    #expect(await router.waitForCount(of: "mobile.sync.fetch", atLeast: 2))

    #expect(await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCount + 1,
        timeoutNanoseconds: 1_000_000_000
    ))
    #expect(store.connectionState == .connected)
    #expect(box.get() === originalTransport)
    collector.unmount()
}

@MainActor
@Test func suspendingForegroundRefreshCancelsInFlightProbeWithoutRedial() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let (store, directory) = try await makeForegroundRecoveryStore(
        router: router,
        box: box,
        clock: clock,
        probeTimeoutNanoseconds: 1_000_000_000
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
    let originalTransport = try #require(box.get())
    await router.holdNextWorkspaceListRequests()
    let probeCount = await router.count(of: "mobile.workspace.list")

    store.resumeForegroundRefresh()
    #expect(await router.waitForCount(
        of: "mobile.workspace.list",
        atLeast: probeCount + 1
    ))
    store.suspendForegroundRefresh()

    #expect(store.connectionRecoveryOwner.phase == .idle)
    #expect(store.connectionState == .connected)
    #expect(store.macConnectionStatus == .connected)
    await router.releaseAllHeld()
    let redialed = await router.waitForCount(
        of: "workspace.list",
        atLeast: 2,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!redialed)
    #expect(box.get() === originalTransport)
}

@MainActor
@Test func foregroundRecoveryRequestedDuringBackgroundWaitsForForegroundProbe() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let (store, directory) = try await makeForegroundRecoveryStore(
        router: router,
        box: box,
        clock: clock,
        probeTimeoutNanoseconds: 1_000_000_000
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
    let originalClient = try #require(store.remoteClient)
    await router.holdNextWorkspaceListRequests()
    let probeCount = await router.count(of: "mobile.workspace.list")

    store.suspendForegroundRefresh()
    store.recoverForegroundConnectionIfNeeded(resyncAfterHealthy: false)
    // A dial launched mid-backgrounding suspends with the process (field
    // traces showed ~9.5s stalls), so the trigger must park until foreground
    // instead of dialing while inactive.
    let probedWhileInactive = await router.waitForCount(
        of: "mobile.workspace.list",
        atLeast: probeCount + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!probedWhileInactive)
    store.resumeForegroundRefresh()

    #expect(await router.waitForCount(
        of: "mobile.workspace.list",
        atLeast: probeCount + 1
    ))
    // Exactly one probe: the parked trigger's replay coalesces into the
    // foreground recovery pass instead of stacking a second dial.
    let doubleProbed = await router.waitForCount(
        of: "mobile.workspace.list",
        atLeast: probeCount + 2,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!doubleProbed)
    await router.releaseAllHeld()
    #expect(try await pollUntil {
        store.connectionRecoveryOwner.phase == .idle
    })
    #expect(store.remoteClient === originalClient)
    #expect(store.connectionState == .connected)
    #expect(store.macConnectionStatus == .connected)
}

@MainActor
@Test func foregroundResumeKeepsDisconnectedRecoveryForegroundOnly() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let (store, directory) = try await makeForegroundRecoveryStore(
        router: router,
        box: box,
        clock: clock
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
    store.connectionState = .disconnected
    await store.releaseRemoteClientForReplacement()
    let failedAttempt = try #require(store.connectionRecoveryOwner.begin(
        trigger: "background-failure",
        sourceConnectionGeneration: store.connectionGeneration,
        probing: false
    ))
    #expect(store.connectionRecoveryOwner.fail(failedAttempt))
    store.applyConnectionRecoveryOwnerState()
    store.didFinishStoredMacReconnectAttempt = true
    let workspaceListCount = await router.count(of: "workspace.list")
    let attachTicketCount = await router.count(of: "mobile.attach_ticket.create")

    // Clearing the foreground identity must not make its stored Mac eligible
    // for secondary aggregation while foreground recovery redials that Mac.
    store.resumeForegroundRefresh()

    #expect(await router.waitForCount(
        of: "workspace.list",
        atLeast: workspaceListCount + 1
    ))
    #expect(try await pollUntil {
        store.connectionState == .connected
            && store.macConnectionStatus == .connected
    })
    #expect(
        await router.count(of: "mobile.attach_ticket.create")
            == attachTicketCount + 1
    )
}

@MainActor
@Test func foregroundResumeDoesNotAggregateWithoutLiveForegroundClient() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let (store, directory) = try await makeForegroundRecoveryStore(
        router: router,
        box: box,
        clock: clock
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
    store.connectionState = .connected
    store.clearRemoteConnectionContext()
    let attachTicketCount = await router.count(of: "mobile.attach_ticket.create")

    store.resumeForegroundRefresh()

    let aggregated = await router.waitForCount(
        of: "mobile.attach_ticket.create",
        atLeast: attachTicketCount + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!aggregated)
}

@MainActor
@Test func foregroundResumeDoesNotRedialWhenReauthenticationIsRequired() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let (store, directory) = try await makeForegroundRecoveryStore(
        router: router,
        box: box,
        clock: clock
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
    #expect(store.disconnectForAuthorizationFailureIfNeeded(
        MobileShellConnectionError.authorizationFailed("test reauthentication")
    ))
    store.didFinishStoredMacReconnectAttempt = true
    let workspaceListCount = await router.count(of: "workspace.list")

    store.resumeForegroundRefresh()

    let redialed = await router.waitForCount(
        of: "workspace.list",
        atLeast: workspaceListCount + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!redialed)
    #expect(store.connectionRequiresReauth)
    #expect(store.connectionState == .disconnected)
}

@MainActor
@Test func foregroundProbeBlocksSecondaryAggregationUntilItSettles() async throws {
    let router = LivenessHostRouter()
    await router.setHostIdentity(
        deviceID: "selected-mac",
        instanceTag: "default",
        displayName: "Selected Mac"
    )
    let selectedRoute = try CmxAttachRoute(
        id: "iroh-selected",
        kind: .iroh,
        endpoint: .peer(
            identity: CmxIrohPeerIdentity(
                endpointID: String(repeating: "a", count: 64)
            ),
            pathHints: []
        ),
        priority: -10_000
    )
    let secondaryRoute = try CmxAttachRoute(
        id: "iroh-secondary",
        kind: .iroh,
        endpoint: .peer(
            identity: CmxIrohPeerIdentity(
                endpointID: String(repeating: "b", count: 64)
            ),
            pathHints: []
        ),
        priority: -10_000
    )
    let secondaryRouter = LivenessHostRouter()
    await secondaryRouter.setHostIdentity(
        deviceID: "secondary-mac",
        instanceTag: "default",
        displayName: "Secondary Mac"
    )
    let (pairedStore, directory) = try ReconnectRouteSelectionTests()
        .makePairedMacStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TestClock()
    try await pairedStore.upsert(
        macDeviceID: "selected-mac",
        displayName: "Selected Mac",
        routes: [selectedRoute],
        instanceTag: "default",
        markActive: true,
        stackUserID: "user-1",
        teamID: nil,
        now: clock.now
    )
    let factory = ForegroundSelectionRouteFactory(
        router: router,
        failingRouteIDs: [],
        routeRouters: [secondaryRoute.id: secondaryRouter]
    )
    let aggregationDefaults = UserDefaults(
        suiteName: "foreground-probe-aggregation-\(UUID().uuidString)"
    )!
    aggregationDefaults.set(false, forKey: "multiMacAggregation")
    let store = MobileShellComposite(
        runtime: LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh]
        ),
        isSignedIn: true,
        pairedMacStore: pairedStore,
        identityProvider: StaticIdentityProvider(userID: "user-1"),
        reachability: AlwaysOnlineReachability(),
        pairingHintDefaults: UserDefaults(
            suiteName: "foreground-probe-hint-\(UUID().uuidString)"
        )!,
        multiMacAggregationDefaults: aggregationDefaults
    )
    #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
    #expect(factory.attemptedRouteIDs() == [selectedRoute.id])
    // Add the secondary after the initial restore. The restore intentionally
    // discovers live peers even when the fan-out preference is off; keeping it
    // out of the initial snapshot isolates the foreground lifecycle race.
    try await pairedStore.upsert(
        macDeviceID: "secondary-mac",
        displayName: "Secondary Mac",
        routes: [secondaryRoute],
        instanceTag: "default",
        markActive: false,
        stackUserID: "user-1",
        teamID: nil,
        now: clock.now.addingTimeInterval(1)
    )
    aggregationDefaults.set(true, forKey: "multiMacAggregation")

    await router.holdNextWorkspaceListRequests()
    let probeCount = await router.count(of: "mobile.workspace.list")
    store.suspendForegroundRefresh()
    store.resumeForegroundRefresh()

    #expect(await router.waitForCount(
        of: "mobile.workspace.list",
        atLeast: probeCount + 1
    ))
    let secondaryDialed = try await pollUntil(attempts: 20) {
        factory.attemptedRouteIDs().contains(secondaryRoute.id)
    }
    #expect(!secondaryDialed)
    #expect(factory.attemptedRouteIDs() == [selectedRoute.id])

    await router.releaseAllHeld()
    #expect(try await pollUntil {
        store.connectionRecoveryOwner.phase == .idle
    })
    await store.remoteClient?.disconnect()
}
}

@MainActor
private func makeForegroundRecoveryStore(
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock,
    probeTimeoutNanoseconds: UInt64 = 200_000_000
) async throws -> (store: MobileShellComposite, directory: URL) {
    let (pairedStore, directory) = try ReconnectRouteSelectionTests()
        .makePairedMacStore()
    let route = try #require(makeTicket(clock: clock).routes.first)
    try await pairedStore.upsert(
        macDeviceID: "test-mac",
        displayName: "Test Mac",
        routes: [route],
        instanceTag: "default",
        markActive: true,
        stackUserID: "user-1",
        teamID: nil,
        now: clock.now
    )
    let store = MobileShellComposite(
        runtime: LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now },
            livenessProbeTimeoutNanoseconds: probeTimeoutNanoseconds
        ),
        isSignedIn: true,
        pairedMacStore: pairedStore,
        identityProvider: StaticIdentityProvider(userID: "user-1"),
        reachability: AlwaysOnlineReachability(),
        pairingHintDefaults: UserDefaults(
            suiteName: "foreground-recovery-\(UUID().uuidString)"
        )!
    )
    #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
    #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
    return (store, directory)
}
