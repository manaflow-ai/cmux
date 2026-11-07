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
@Test func longBackgroundUnansweredProbesRedialHalfOpenSession() async throws {
    // https://github.com/manaflow-ai/cmux/issues/26530: after a long
    // background the Mac has idled the session out, but the phone's native
    // connection still reads open. Two unanswered probes must replace it
    // instead of keeping a dead session that only looks connected.
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
    let originalTransport = try #require(box.get())
    let originalClient = try #require(store.remoteClient)
    let probeCount = await router.count(of: "mobile.workspace.list")
    let statusCount = await router.count(of: "mobile.host.status")

    store.suspendForegroundRefresh()
    clock.advance(by: MobileShellComposite.foregroundProbeSilenceIsDeadAfterBackground + 1)
    await router.holdNextWorkspaceListRequests()
    await router.holdNextHostStatusRequests()
    store.resumeForegroundRefresh()

    #expect(await router.waitForCount(
        of: "mobile.workspace.list",
        atLeast: probeCount + 1
    ))
    // The confirming probe is a direct status request, not a second list.
    #expect(await router.waitForCount(
        of: "mobile.host.status",
        atLeast: statusCount + 1
    ))
    #expect(try await pollUntil {
        store.remoteClient !== originalClient
            && store.connectionState == .connected
            && store.connectionRecoveryOwner.phase == .idle
            && store.macConnectionStatus == .connected
    })
    #expect(box.get() !== originalTransport)
    #expect(await originalTransport.isTransportClosed())
    #expect(!store.isRecoveringConnection)
}

@MainActor
@Test func longBackgroundAnsweredConfirmationKeepsSession() async throws {
    // A stalled list fetch alone is not proof: when the direct status
    // request answers, the Mac still serves this session and it is kept.
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
    let originalTransport = try #require(box.get())
    let originalClient = try #require(store.remoteClient)
    let statusCount = await router.count(of: "mobile.host.status")

    store.suspendForegroundRefresh()
    clock.advance(by: MobileShellComposite.foregroundProbeSilenceIsDeadAfterBackground + 1)
    await router.holdNextWorkspaceListRequests()
    store.resumeForegroundRefresh()

    #expect(await router.waitForCount(
        of: "mobile.host.status",
        atLeast: statusCount + 1
    ))
    #expect(try await pollUntil {
        store.connectionRecoveryOwner.phase == .idle && !store.isRecoveringConnection
    })
    #expect(store.remoteClient === originalClient)
    #expect(box.get() === originalTransport)
    #expect(store.macConnectionStatus == .connected)
}

@MainActor
@Test func longBackgroundProbeAuthFailureSettlesWithoutReconnecting() async throws {
    // An auth error during the probe tears the session down for re-auth.
    // The probe must settle so Reconnecting never masks the disconnected
    // state (which would also unblock terminal input).
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let indicatorClock = ControlPoolManualClock()
    let (store, directory) = try await makeForegroundRecoveryStore(
        router: router,
        box: box,
        clock: clock,
        indicatorClock: indicatorClock,
        probeTimeoutNanoseconds: 10_000_000_000
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
    let probeCount = await router.count(of: "mobile.workspace.list")

    store.suspendForegroundRefresh()
    clock.advance(by: MobileShellComposite.foregroundProbeSilenceIsDeadAfterBackground + 1)
    await router.holdNextWorkspaceListRequests()
    // The router numbers both list methods together.
    let listRequestCount = probeCount + (await router.count(of: "workspace.list"))
    await router.failWorkspaceListRequest(number: listRequestCount + 1, code: "auth_required")
    store.resumeForegroundRefresh()

    #expect(await router.waitForCount(
        of: "mobile.workspace.list",
        atLeast: probeCount + 1
    ))
    await indicatorClock.waitForSleep()
    let indicatorTask = try #require(store.foregroundProbeIndicatorTask)
    indicatorClock.advance(by: .milliseconds(399))
    #expect(indicatorClock.sleeperCount == 1)
    #expect(!store.isRecoveringConnection)
    indicatorClock.advance(by: .milliseconds(1))
    await indicatorTask.value
    #expect(store.isRecoveringConnection)
    await router.releaseAllHeld()
    #expect(try await pollUntil {
        store.connectionState == .disconnected
            && store.connectionRecoveryOwner.phase == .idle
    })
    #expect(!store.isRecoveringConnection)
    #expect(store.connectionRequiresReauth)
}

@MainActor
@Test func longBackgroundProbeShowsReconnectingUntilItSettles() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let indicatorClock = ControlPoolManualClock()
    let (store, directory) = try await makeForegroundRecoveryStore(
        router: router,
        box: box,
        clock: clock,
        indicatorClock: indicatorClock,
        probeTimeoutNanoseconds: 10_000_000_000
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
    let originalClient = try #require(store.remoteClient)
    let probeCount = await router.count(of: "mobile.workspace.list")

    store.suspendForegroundRefresh()
    clock.advance(by: MobileShellComposite.foregroundProbeSilenceIsDeadAfterBackground + 1)
    await router.holdNextWorkspaceListRequests()
    store.resumeForegroundRefresh()

    #expect(await router.waitForCount(
        of: "mobile.workspace.list",
        atLeast: probeCount + 1
    ))
    await indicatorClock.waitForSleep()
    let indicatorTask = try #require(store.foregroundProbeIndicatorTask)
    indicatorClock.advance(by: .milliseconds(399))
    #expect(indicatorClock.sleeperCount == 1)
    #expect(!store.isRecoveringConnection)
    indicatorClock.advance(by: .milliseconds(1))
    await indicatorTask.value
    #expect(store.isRecoveringConnection)
    // The probe keeps the session and the keyboard: only presentation changes.
    #expect(store.connectionState == .connected)
    #expect(store.remoteClient === originalClient)
    #expect(!store.connectionRecoveryFailed)

    await router.releaseAllHeld()
    #expect(try await pollUntil {
        store.connectionRecoveryOwner.phase == .idle && !store.isRecoveringConnection
    })
    #expect(store.remoteClient === originalClient)
    #expect(store.macConnectionStatus == .connected)
}

@MainActor
@Test func shortBackgroundProbeNeverShowsReconnecting() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let indicatorClock = ControlPoolManualClock()
    let (store, directory) = try await makeForegroundRecoveryStore(
        router: router,
        box: box,
        clock: clock,
        indicatorClock: indicatorClock,
        probeTimeoutNanoseconds: 10_000_000_000
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
    let probeCount = await router.count(of: "mobile.workspace.list")

    store.suspendForegroundRefresh()
    clock.advance(by: 5)
    await router.holdNextWorkspaceListRequests()
    store.resumeForegroundRefresh()

    #expect(await router.waitForCount(
        of: "mobile.workspace.list",
        atLeast: probeCount + 1
    ))
    // A short dwell never schedules an indicator, even past its grace.
    #expect(store.foregroundProbeIndicatorTask == nil)
    #expect(indicatorClock.sleeperCount == 0)
    indicatorClock.advance(by: .seconds(1))
    #expect(!store.isRecoveringConnection)
    await router.releaseAllHeld()
    #expect(try await pollUntil { store.connectionRecoveryOwner.phase == .idle })
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
}

@MainActor
private func makeForegroundRecoveryStore(
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock,
    indicatorClock: any Clock<Duration> = ContinuousClock(),
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
        )!,
        foregroundProbeIndicatorClock: indicatorClock
    )
    #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
    #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
    return (store, directory)
}
