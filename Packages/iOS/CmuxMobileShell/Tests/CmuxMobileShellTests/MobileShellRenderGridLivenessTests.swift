import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

// Regression coverage for the render-grid liveness watchdog false-fire
// (Release-sim bisect, 2026-06-10): the phone logged "render-grid stream
// silent for 10499ms, re-subscribing" every ~10.5s plus "subscribe failed
// reason=start: requestTimedOut" while the Mac demonstrably kept the
// connection healthy. Two defects combined:
//
// 1. The liveness clock was stamped only inside the listener's `for await`
//    consumer loop, which did not start until the `mobile.events.subscribe`
//    ack round-trip completed. Events yielded into the subscription stream
//    during that window were buffered invisibly, so the watchdog read a
//    healthy establishing stream as silence (and its resync then CANCELLED
//    the in-flight subscribe, which surfaces as `requestTimedOut`).
// 2. A healthy idle terminal legitimately pushes no events at all (the Mac
//    dedupes render-grid emits by row signature + stateSeq), so wall-clock
//    silence alone can never distinguish "idle" from "dead". The watchdog
//    needs a bounded host probe before it may declare death.


// MARK: - Tests

/// The decoupling found by the bisect: events that the transport delivers
/// while the `mobile.events.subscribe` ack is still in flight must reach the
/// real consumer (and therefore the liveness clock), not pile up unconsumed
/// in the subscription stream's buffer behind the ack await.
@MainActor
@Test func renderGridEventsArrivingDuringStartSubscribeAreConsumed() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    await router.setHoldSubscribe(true)
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    // The listener has sent its start subscribe; the ack is parked.
    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must request the server-side subscription")

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")

    // The Mac pushes a live render-grid event while the subscribe ack is
    // still pending (the server-side subscription from a previous generation
    // keeps pushing across re-subscribes; the ack is an enable handshake,
    // not a delivery precondition).
    let event = try renderGridEventFrame(surfaceID: "live-terminal", seq: 5, text: "live")
    let transport = try #require(box.get())
    await transport.deliver(event)

    let delivered = try await pollUntil { collector.lines.isEmpty == false }
    #expect(
        delivered,
        "render-grid events must be consumed while the start-subscribe ack is in flight; buffering them unconsumed is what made a healthy stream look silent to the liveness watchdog"
    )
    #expect(collector.lines.first?.contains("live") == true)

    await router.releaseAllHeld()
    collector.unmount()
}

/// A healthy idle stream produces zero events (the Mac dedupes unchanged
/// frames), so silence alone must not tear the subscription down. The
/// watchdog may verify the silence with a bounded idempotent re-subscribe
/// probe, but when the host answers it must stay quiet: no listener restart
/// (observable as a second `mobile.host.status` capability resolve) and no
/// full-grid replay. Without this, the phone tore down and full-grid
/// re-replayed every ~10.5s forever on any idle terminal.
@MainActor
@Test func watchdogDoesNotTearDownHealthyIdleStream() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink arms exactly one cold-attach replay")

    // Idle past the silence threshold: no events at all, host healthy.
    clock.advance(by: 10)
    store.debugRunRenderGridLivenessCheckForTesting()

    // A teardown would restart the listener, which re-resolves capabilities
    // (mobile.host.status request number 2) and re-replays the mounted sink.
    let restarted = try await pollUntil(attempts: 60) {
        await router.count(of: "mobile.host.status") >= 2
    }
    #expect(
        restarted == false,
        "the watchdog must not tear down a healthy idle stream; the host answered the probe, so silence only means the terminal had nothing to say"
    )

    // The probe outcome must reset the silence window: an immediate second
    // evaluation stays quiet too.
    store.debugRunRenderGridLivenessCheckForTesting()
    let restartedAfterRecheck = try await pollUntil(attempts: 30) {
        await router.count(of: "mobile.host.status") >= 2
    }
    #expect(restartedAfterRecheck == false)
    let replayCount = await router.count(of: "mobile.terminal.replay")
    #expect(replayCount == 1, "a healthy idle stream must not generate replay traffic beyond the mount's cold-attach replay")

    // The stream was never restarted: the original subscription still
    // delivers straight into the mounted sink.
    let event = try renderGridEventFrame(surfaceID: "live-terminal", seq: 9, text: "still-alive")
    let transport = try #require(box.get())
    await transport.deliver(event)
    let delivered = try await pollUntil { collector.lines.isEmpty == false }
    #expect(delivered, "the original stream must still be consumed after the probe")
    collector.unmount()
}

/// A successful probe that REPAIRED a lost registration (the host reports
/// `already_subscribed: false`) must replay mounted surfaces: render-grid
/// deltas emitted while the registration was absent were never delivered, so
/// delta continuity is broken even though the channel is healthy again. The
/// phone-side listener stream is intact, so the repair must not restart the
/// listener (no second capability resolve).
@MainActor
@Test func probeRepairingLostSubscriptionReplaysMountedSurfaces() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink arms exactly one cold-attach replay")

    // The host loses the registration while the RPC channel stays healthy.
    await router.dropSubscription()
    let workspaceListsBeforeRepair = await router.count(of: "mobile.workspace.list")
        + router.count(of: "workspace.list")
    clock.advance(by: 10)
    store.debugRunRenderGridLivenessCheckForTesting()

    let replayed = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 2 }
    #expect(
        replayed,
        "a probe that reinstalls a lost registration must request a catch-up replay for mounted surfaces; deltas emitted during the gap were never delivered"
    )
    let hostStatusCount = await router.count(of: "mobile.host.status")
    #expect(hostStatusCount == 1, "the repair must not restart the listener; the phone-side stream is intact")
    // workspace.updated events were missed during the gap too: the repair must
    // re-fetch the authoritative workspace list.
    let workspaceRefetched = try await pollUntil {
        let current = await router.count(of: "mobile.workspace.list")
            + router.count(of: "workspace.list")
        return current > workspaceListsBeforeRepair
    }
    #expect(workspaceRefetched, "the repaired subscription also carries workspace.updated, so the workspace list must be re-fetched")

    // The repaired stream delivers straight into the still-mounted sink.
    let event = try renderGridEventFrame(surfaceID: "live-terminal", seq: 11, text: "repaired")
    let transport = try #require(box.get())
    await transport.deliver(event)
    let delivered = try await pollUntil { collector.lines.contains { $0.contains("repaired") } }
    #expect(delivered, "the original stream must still be consumed after the repair")
    collector.unmount()
}

/// If terminal input reports the Mac has advanced past the last rendered
/// frame, render-grid mode first waits for the live event stream instead of
/// immediately replaying. When the re-subscribe ack says the host-side
/// registration had been absent, that wait cannot succeed for the already
/// emitted input frame; the mounted surface needs an explicit catch-up replay.
@MainActor
@Test func inputSeqWaitRepairingLostSubscriptionReplaysMountedSurface() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    await router.setReplayFrames([
        (seq: 4, text: "old"),
        (seq: 12, text: "repaired-input"),
    ])
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink arms the cold-attach replay")
    let deliveredInitialReplay = try await pollUntil { collector.lines.contains { $0.contains("old") } }
    #expect(deliveredInitialReplay, "the mount replay establishes the local rendered sequence")

    await router.dropSubscription()
    await store.submitTerminalRawInput(Data("x".utf8), surfaceID: "live-terminal")

    let replayedAfterRepair = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 2 }
    #expect(
        replayedAfterRepair,
        "input_seq_wait must replay the mounted surface when its re-subscribe repaired a lost host registration"
    )
    let deliveredRepairReplay = try await pollUntil { collector.lines.contains { $0.contains("repaired-input") } }
    #expect(deliveredRepairReplay)
    collector.unmount()
}

/// A repaired `input_seq_wait` re-subscribe is global: when the host reports
/// `already_subscribed: false`, every mounted surface may have missed
/// render-grid events during the registration gap, not just the surface that
/// sent input.
@MainActor
@Test func inputSeqWaitRepairingLostSubscriptionReplaysAllMountedSurfaces() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    await router.setReplayFrames([
        (seq: 4, text: "primary-old"),
        (seq: 12, text: "primary-repaired"),
    ])
    await router.setReplayFrames([
        (seq: 6, text: "peer-old"),
        (seq: 14, text: "peer-repaired"),
    ], surfaceID: "secondary-terminal")
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    let primaryCollector = OutputCollector()
    let secondaryCollector = OutputCollector()
    primaryCollector.mount(store: store, surfaceID: "live-terminal")
    secondaryCollector.mount(store: store, surfaceID: "secondary-terminal")
    let sawMountReplays = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 2 }
    #expect(sawMountReplays, "mounting two sinks arms cold-attach replays for both")
    let deliveredInitialReplays = try await pollUntil {
        primaryCollector.lines.contains { $0.contains("primary-old") }
            && secondaryCollector.lines.contains { $0.contains("peer-old") }
    }
    #expect(deliveredInitialReplays, "the mount replays establish both local rendered sequences")

    await router.dropSubscription()
    await store.submitTerminalRawInput(Data("x".utf8), surfaceID: "live-terminal")

    let replayedPrimaryAfterRepair = try await pollUntil {
        await router.count(of: "mobile.terminal.replay", surfaceID: "live-terminal") >= 2
    }
    let replayedSecondaryAfterRepair = try await pollUntil {
        await router.count(of: "mobile.terminal.replay", surfaceID: "secondary-terminal") >= 2
    }
    #expect(replayedPrimaryAfterRepair)
    #expect(
        replayedSecondaryAfterRepair,
        "a repaired global subscription must replay every mounted surface, including surfaces that did not send the input"
    )
    let deliveredRepairReplays = try await pollUntil {
        primaryCollector.lines.contains { $0.contains("primary-repaired") }
            && secondaryCollector.lines.contains { $0.contains("peer-repaired") }
    }
    #expect(deliveredRepairReplays)
    primaryCollector.unmount()
    secondaryCollector.unmount()
}

/// A repaired refresh that was started by an empty-list caller must still
/// perform the global repair work: replay every mounted surface and refresh
/// workspace state.
@MainActor
@Test func defaultRefreshRepairingLostSubscriptionReplaysMountedSurfaces() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    await router.setTerminalFidelity("raw_bytes")
    await router.setCapabilities(["events.v1", "terminal.replay.v1"])
    await router.delaySubscribeRequest(number: 2)
    await router.setReplayFrames([
        (seq: 4, text: "primary-old"),
        (seq: 8, text: "primary-gap"),
        (seq: 12, text: "primary-repaired"),
    ])
    await router.setReplayFrames([
        (seq: 6, text: "peer-old"),
        (seq: 14, text: "peer-repaired"),
    ], surfaceID: "secondary-terminal")
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    let primaryCollector = OutputCollector()
    let secondaryCollector = OutputCollector()
    primaryCollector.mount(store: store, surfaceID: "live-terminal")
    secondaryCollector.mount(store: store, surfaceID: "secondary-terminal")
    let deliveredInitialReplays = try await pollUntil {
        primaryCollector.lines.contains { $0.contains("primary-old") }
            && secondaryCollector.lines.contains { $0.contains("peer-old") }
    }
    #expect(deliveredInitialReplays, "the mount replays establish both local rendered sequences")

    let workspaceListsBeforeRepair = await router.count(of: "mobile.workspace.list")
        + router.count(of: "workspace.list")
    await router.dropSubscription()
    let gapEvent = try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 20, text: "gap")
    let transport = try #require(box.get())
    await transport.deliver(gapEvent)

    let defaultRefreshStarted = try await pollUntil {
        await router.count(of: "mobile.events.subscribe") >= 2
    }
    #expect(defaultRefreshStarted, "a byte gap starts a default refresh with no repair replay list")

    await router.releaseAllHeld()
    let replayedSecondaryAfterRepair = try await pollUntil {
        await router.count(of: "mobile.terminal.replay", surfaceID: "secondary-terminal") >= 2
    }
    #expect(
        replayedSecondaryAfterRepair,
        "a repaired empty-list refresh must replay all mounted surfaces, not only the surface that triggered the refresh"
    )
    let deliveredRepairReplay = try await pollUntil {
        secondaryCollector.lines.contains { $0.contains("peer-repaired") }
    }
    #expect(deliveredRepairReplay)
    let workspaceRefetched = try await pollUntil {
        let current = await router.count(of: "mobile.workspace.list")
            + router.count(of: "workspace.list")
        return current > workspaceListsBeforeRepair
    }
    #expect(workspaceRefetched, "any repaired subscription must re-fetch workspace state, even without an explicit replay list")
    primaryCollector.unmount()
    secondaryCollector.unmount()
}

/// The watchdog's original purpose (the ~85s silent-death hang) must keep
/// working: silence past the threshold plus a host that stops answering the
/// probe must still tear down and re-subscribe.
@MainActor
@Test func watchdogStillResubscribesGenuinelyDeadStream() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    // The host stops answering the next mobile.events.subscribe (the
    // watchdog's re-assert probe), modeling a dead push path while the
    // request had already left the phone.
    await router.holdSubscribeRequest(number: 2)
    clock.advance(by: 10)
    store.debugRunRenderGridLivenessCheckForTesting()

    // Recovery restarts the listener, which re-resolves capabilities: a
    // second mobile.host.status request is the teardown-and-restart proof.
    let restarted = try await pollUntil(attempts: 600) {
        await router.count(of: "mobile.host.status") >= 2
    }
    #expect(
        restarted,
        "a stream that is silent past the threshold AND whose host stops answering the subscription probe must still be torn down and re-subscribed"
    )
    await router.releaseAllHeld()
}

/// A transport that drops before the start handshake completes must converge
/// to `.unavailable`, not livelock in `.reconnecting`: without the guard, the
/// stream-end restart supersedes the listener generation, so the parked start
/// ack's failure verdict is silently dropped by its generation check and the
/// loop re-arms forever (observed as the ipad-only CI failure of
/// `macConnectionStatusMarksUnavailableWhenEventStreamCloses`, where the race
/// occasionally lands the other way on faster simulators).
@MainActor
@Test func streamEndingBeforeStartAckMarksUnavailable() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    await router.setHoldSubscribe(true)
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must send the start subscribe")

    // The transport dies while the enable handshake is still parked.
    let transport = try #require(box.get())
    await transport.close()

    let unavailable = try await pollUntil { store.macConnectionStatus == .unavailable }
    #expect(
        unavailable,
        "a stream that ends before its subscribe ack must converge to unavailable, not loop reconnecting"
    )
    #expect(store.connectionRecoveryFailed)
}

/// Older Macs used `workspace.actions.v1` for rename/pin only. Newly added
/// read-state and close actions need separate capability bits so a newer iPhone
/// does not show controls that an older Mac will reject at runtime.
@MainActor
@Test func workspaceReadStateAndCloseCapabilitiesAreVersionGated() async throws {
    let oldMacClock = TestClock()
    let oldMacRouter = LivenessHostRouter()
    let oldMacBox = TransportBox()
    await oldMacRouter.setCapabilities([
        "events.v1",
        "terminal.render_grid.v1",
        "terminal.replay.v1",
        "workspace.actions.v1",
    ])
    let oldMacStore = try await makeConnectedStore(router: oldMacRouter, box: oldMacBox, clock: oldMacClock)
    let oldMacResolved = try await pollUntil { await oldMacRouter.count(of: "mobile.host.status") >= 1 }
    #expect(oldMacResolved)
    #expect(oldMacStore.supportsWorkspaceActions)
    #expect(oldMacStore.supportsWorkspaceReadStateActions == false)
    #expect(oldMacStore.supportsWorkspaceCloseActions == false)

    let currentMacClock = TestClock()
    let currentMacRouter = LivenessHostRouter()
    let currentMacBox = TransportBox()
    await currentMacRouter.setCapabilities([
        "events.v1",
        "terminal.render_grid.v1",
        "terminal.replay.v1",
        "workspace.actions.v1",
        "workspace.read_state.v1",
        "workspace.close.v1",
    ])
    let currentMacStore = try await makeConnectedStore(router: currentMacRouter, box: currentMacBox, clock: currentMacClock)
    let currentMacResolved = try await pollUntil { await currentMacRouter.count(of: "mobile.host.status") >= 1 }
    #expect(currentMacResolved)
    #expect(currentMacStore.supportsWorkspaceActions)
    #expect(currentMacStore.supportsWorkspaceReadStateActions)
    #expect(currentMacStore.supportsWorkspaceCloseActions)
}
