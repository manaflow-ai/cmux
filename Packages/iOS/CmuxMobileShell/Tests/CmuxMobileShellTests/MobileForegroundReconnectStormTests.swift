import CMUXMobileCore
import CmuxMobileChanges
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/10482:
// foregrounding the iOS app after a background triggered a reconnect storm.
// A freshly (re)established terminal event subscription that ends — or whose
// enable handshake is rejected — before delivering any event fired
// `recoverDeadConnection(.eventStreamEnded/.subscriptionStartFailed)` with NO
// backoff. The redial succeeds, restarts the same failing stream, and ends
// again at scheduler speed, pinning the main thread (94% CPU), full-replaying
// terminal scrollback (~20MB/burst on cellular), and churning the
// files-changed chip on every cycle.
//
// These tests assert the four acceptance criteria at the store layer:
//   B. a repeatedly-barren event stream backs off instead of tight-looping.
//   A. the files-changed chips survive a transient reconnect (no 51->0->51).
//   C. a reconnect with a live on-screen mirror resumes (no full scrollback
//      re-hydration) rather than re-downloading history.
//   D. the dead-stream storm does not fire an unbounded number of terminal
//      replays (each replay repaints/anchors the grid and resets scroll), and
//      the phone's reported viewport geometry survives the reconnect.

// MARK: - B. Dead event-stream redials are rate-limited (single-flight + backoff)

@MainActor
@Test func foregroundDeadEventStreamRedialLoopIsRateLimited() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let controlClock = ControlPoolManualClock()
    let (store, directory) = try await makeStormRecoveryStore(
        router: router,
        box: box,
        clock: clock,
        controlClock: controlClock
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }

    #expect(store.connectionState == .connected)
    let subscribeCountBefore = await router.count(of: "mobile.events.subscribe")

    // Model a host that keeps accepting the transport dial but rejects every
    // subscription enable. On current main each rejected subscribe fires
    // recoverDeadConnection(.subscriptionStartFailed), which redials, restarts
    // the stream, and rejects again — a back-off-free loop at scheduler speed.
    await router.failNextSubscribeRequests(count: 25)
    store.resyncTerminalOutput(reason: "test.deadStreamStorm", restartEventStream: true)

    // A rate-limited recovery parks the redial on the control-plane backoff
    // clock instead of spinning. On main no backoff exists, so this never
    // becomes true (and the loop burns through every scripted failure).
    let backoffEngaged = try await pollUntil { controlClock.sleeperCount >= 1 }
    #expect(
        backoffEngaged,
        "a repeatedly-barren event stream must back off, not redial in a tight loop"
    )

    // Only a couple of immediate redials before the backoff gate holds. On main
    // this instead climbs through the whole scripted-failure budget.
    let subscribeDelta = await router.count(of: "mobile.events.subscribe") - subscribeCountBefore
    #expect(
        subscribeDelta <= 5,
        "dead-stream redials must be rate-limited; saw \(subscribeDelta) subscribe attempts"
    )

    // Advancing the backoff clock releases exactly one further redial, which —
    // still barren — re-parks on a longer backoff instead of resuming the storm.
    let subscribeBeforeAdvance = await router.count(of: "mobile.events.subscribe")
    controlClock.advance(by: .seconds(60))
    _ = try await pollUntil {
        await router.count(of: "mobile.events.subscribe") > subscribeBeforeAdvance
    }
    let subscribeAfterAdvance = await router.count(of: "mobile.events.subscribe")
    #expect(
        subscribeAfterAdvance - subscribeBeforeAdvance <= 3,
        "each backoff tick must release a bounded redial, not reopen the storm"
    )
}

// MARK: - A. Files-changed chips survive a transient reconnect

@MainActor
@Test func workspaceChangesChipsSurviveTransientReconnect() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    // The "51 files" chip content the review sheet / hint / toolbar all read.
    store.setWorkspaceChangeChipsByWorkspaceID([
        "live-workspace": MobileWorkspaceChangesChip(
            filesChanged: 51,
            additions: 120,
            deletions: 8
        ),
    ])
    #expect(store.workspaceChangeChipsByWorkspaceID["live-workspace"]?.filesChanged == 51)

    // A transient reconnect flips connectionState .connected -> .disconnected
    // -> .connected. On main the disconnect edge wiped every chip to empty
    // (filesChanged 51 -> 0) and the reconnect refetch restored it (0 -> 51),
    // and that 51->0->51 churn re-presented the files-changed hint every cycle.
    store.connectionState = .disconnected
    #expect(
        store.workspaceChangeChipsByWorkspaceID["live-workspace"]?.filesChanged == 51,
        "a transient disconnect must not drop the files-changed chip to zero"
    )

    store.connectionState = .connected
    #expect(
        store.workspaceChangeChipsByWorkspaceID["live-workspace"]?.filesChanged == 51,
        "reconnecting must not churn the files-changed chip content"
    )
}

// MARK: - C. A reconnect with a live mirror resumes (no full scrollback replay)

@MainActor
@Test func reconnectWithLiveMirrorResumesWithoutFullScrollbackReplay() async throws {
    let router = LivenessHostRouter()
    // Screen-anchored render grid is what carries a deep local scrollback, so
    // its replay is where the phone chooses full hydration vs a cheap repaint.
    await router.setCapabilities([
        "events.v1",
        "terminal.render_grid.v1",
        "terminal.render_grid.screen_anchor.v1",
        "terminal.replay.v1",
    ])
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"
    #expect(try await pollUntil { store.usesScreenAnchoredRenderGrid })

    await router.enqueueReplayTexts(["cold-replay"])
    let iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    _ = iterator
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)

    // Cold attach hydrates this device's deep scrollback (the mirror was blank).
    let coldReplay = try #require(await router.requests(for: "mobile.terminal.replay").first)
    #expect(
        (coldReplay.maxScrollbackRows ?? 0) > 0,
        "a cold attach must hydrate scrollback"
    )

    // The surface now has a populated on-screen mirror with a delivery cursor,
    // exactly as a steady-state terminal does.
    store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] = 100
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] != nil)

    // Simulate a reconnect: the recovery path clears the live client, which
    // resets terminal output tracking (dropping the delivery cursor), then
    // installs a fresh one. The on-screen mirror survives — the surface is
    // still mounted — so the reconnect should repaint the visible screen, not
    // re-download the entire scrollback again.
    let replayCountBeforeReconnect = await router.count(of: "mobile.terminal.replay")
    store.remoteClient = nil
    try installFreshLivenessRemoteClient(on: store, router: router, box: box, clock: clock)
    // A real reconnect re-resolves the host capabilities and transport during
    // its handshake; the manual client swap above skips that, so restore the
    // screen-anchored render-grid state the reconnect would negotiate.
    store.terminalOutputTransport = .renderGrid
    store.supportedHostCapabilities = [
        "events.v1",
        "terminal.render_grid.v1",
        "terminal.render_grid.screen_anchor.v1",
        "terminal.replay.v1",
    ]
    #expect(store.usesScreenAnchoredRenderGrid)
    store.requestTerminalReplay(surfaceID: surfaceID)

    #expect(await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountBeforeReconnect + 1
    ))
    let reconnectReplay = try #require(await router.requests(for: "mobile.terminal.replay").last)
    #expect(
        reconnectReplay.maxScrollbackRows == 0,
        "a reconnect that keeps a live mirror must resume (max_scrollback_rows 0), not re-hydrate the full scrollback"
    )
}

// MARK: - D. The storm does not repeatedly replay; viewport geometry survives

@MainActor
@Test func deadStreamStormDoesNotRepeatedlyReplayAndKeepsViewport() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let controlClock = ControlPoolManualClock()
    let (store, directory) = try await makeStormRecoveryStore(
        router: router,
        box: box,
        clock: clock,
        controlClock: controlClock
    )
    defer {
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    // Pin a viewport geometry; it drives scroll/grid sizing and must survive a
    // reconnect so scrolling keeps working afterward.
    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 40)
    let viewportKey = MobileTerminalViewportKey(
        workspaceID: "live-workspace",
        terminalID: MobileTerminalPreview.ID(rawValue: surfaceID)
    )
    #expect(store.reportedViewportSizesByTerminalKey[viewportKey]?.columns == 80)

    // Drive the dead-stream storm. On main every redial resyncs and re-anchors
    // the terminal grid (which resets the user's scroll) with no backoff; the
    // main thread never settles, which is what freezes touch scrolling.
    await router.failNextSubscribeRequests(count: 25)
    store.resyncTerminalOutput(reason: "test.stormReplay", restartEventStream: true)

    // Rate-limited recovery settles onto the backoff clock instead of spinning.
    // On main this never happens, so the reconnect loop keeps re-anchoring the
    // grid and pinning the main thread.
    let backoffEngaged = try await pollUntil { controlClock.sleeperCount >= 1 }
    #expect(
        backoffEngaged,
        "the reconnect loop must settle so the main thread is free for scrolling"
    )

    // Once parked on the backoff, the terminal is not replayed again until the
    // backoff clock advances: no ongoing re-anchoring that resets scroll and no
    // main-thread churn. (On main the loop never parks, so it keeps replaying.)
    // Wait on the router's arrival signal (bounded) and assert no further replay
    // lands, rather than sleeping a fixed interval.
    let replaysWhenParked = await router.count(of: "mobile.terminal.replay")
    let replayedAgain = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replaysWhenParked + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!replayedAgain, "a parked reconnect must stop replaying the terminal")

    // The reported viewport geometry survives the reconnect so scrolling works.
    #expect(
        store.reportedViewportSizesByTerminalKey[viewportKey]?.columns == 80,
        "viewport geometry must survive a reconnect"
    )
}

// MARK: - Support

@MainActor
private func makeStormRecoveryStore(
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock,
    controlClock: ControlPoolManualClock,
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
            suiteName: "storm-recovery-\(UUID().uuidString)"
        )!,
        controlPlaneSchedulingClock: controlClock
    )
    #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
    #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
    #expect(try await pollUntil { store.connectionState == .connected })
    return (store, directory)
}
