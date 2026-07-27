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
    #expect(store.macConnectionStatus == .connected)
}

@MainActor
@Test func failedForegroundProbeStillSurfacesRedialRecoveryState() async throws {
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
        if case .redialing = store.connectionRecoveryOwner.phase {
            return store.isRecoveringConnection
        }
        return false
    })
    await router.releaseAllHeld()
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
@Test func foregroundResumeAbandonsProbeStartedDuringBackgroundAndProbesAgain() async throws {
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
    let originalClient = try #require(store.remoteClient)
    await router.holdNextWorkspaceListRequests()
    let probeCount = await router.count(of: "mobile.workspace.list")

    store.suspendForegroundRefresh()
    store.recoverForegroundConnectionIfNeeded(resyncAfterHealthy: false)
    #expect(await router.waitForCount(
        of: "mobile.workspace.list",
        atLeast: probeCount + 1
    ))
    store.resumeForegroundRefresh()

    #expect(await router.waitForCount(
        of: "mobile.workspace.list",
        atLeast: probeCount + 2
    ))
    #expect(try await pollUntil {
        store.connectionRecoveryOwner.phase == .idle
    })
    #expect(store.remoteClient === originalClient)
    #expect(store.connectionState == .connected)
    #expect(store.macConnectionStatus == .connected)
}

@MainActor
@Test func foregroundResumeRedialsFinishedDisconnectedRecovery() async throws {
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
    store.clearRemoteConnectionContext()
    let failedAttempt = try #require(store.connectionRecoveryOwner.begin(
        trigger: "background-failure",
        sourceConnectionGeneration: store.connectionGeneration,
        probing: false
    ))
    #expect(store.connectionRecoveryOwner.fail(failedAttempt))
    store.applyConnectionRecoveryOwnerState()
    store.didFinishStoredMacReconnectAttempt = true
    let workspaceListCount = await router.count(of: "workspace.list")

    store.resumeForegroundRefresh()

    #expect(await router.waitForCount(
        of: "workspace.list",
        atLeast: workspaceListCount + 1
    ))
    #expect(try await pollUntil {
        store.connectionState == .connected
            && store.macConnectionStatus == .connected
    })
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
