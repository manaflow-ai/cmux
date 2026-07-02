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
    let event = try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 5,
        text: "live",
        activeScreen: .alternate
    )
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

@MainActor
@Test func renderGridCapableHostUsesHybridTerminalOutputSubscription() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    #expect(store.connectionState == .connected)

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must request the server-side subscription")
    let topics = await router.topics(for: "mobile.events.subscribe").last ?? []
    #expect(topics.contains("terminal.bytes"))
    #expect(topics.contains("terminal.render_grid"))
}

@MainActor
@Test func renderGridOnlyHostKeepsPrimaryRenderGridDelivery() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    #expect(store.connectionState == .connected)

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must request the server-side subscription")
    let topics = await router.topics(for: "mobile.events.subscribe").last ?? []
    #expect(topics.contains("terminal.render_grid"))
    #expect(topics.contains("terminal.bytes") == false)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(surfaceID: "live-terminal", seq: 3, text: "grid-only"))
    let gridDelivered = try await pollUntil { collector.lines.contains { $0.contains("grid-only") } }
    #expect(gridDelivered, "render-grid-only hosts must keep painting primary render-grid frames")
    collector.unmount()
}

@MainActor
@Test func primaryRenderGridEventDoesNotPreemptRawBytes() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try renderGridEventFrame(surfaceID: "live-terminal", seq: 3, text: "grid"))
    let policyDelivered = try await pollUntil { collector.viewportPolicies.last == .natural }
    #expect(policyDelivered, "advisory primary render-grid events must still deliver their viewport policy")
    #expect(
        collector.lines.contains { $0.contains("grid") } == false,
        "primary render-grid events are advisory in hybrid mode; raw bytes own full-height primary rendering"
    )

    await transport.deliver(try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 0, text: "raw"))
    let rawDelivered = try await pollUntil { collector.lines.contains { $0.contains("raw") } }
    #expect(rawDelivered, "advisory primary render-grid must not advance delivered seq and starve overlapping raw bytes")
    #expect(
        collector.lines.contains { $0.contains("grid") } == false,
        "primary render-grid events are advisory in hybrid mode; raw bytes own full-height primary rendering"
    )
    #expect(collector.viewportPolicies.last == .natural)
    collector.unmount()
}

@MainActor
@Test func hybridPrimaryInputBehindRequestsReplayInsteadOfWaitingOnAdvisoryRenderGrid() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 0, text: "raw"))
    let rawDelivered = try await pollUntil { collector.lines.contains { $0.contains("raw") } }
    #expect(rawDelivered)

    await store.submitTerminalRawInput(Data("x".utf8), surfaceID: "live-terminal")
    let inputSent = try await pollUntil { await router.count(of: "terminal.input") >= 1 }
    #expect(inputSent)
    let replayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountAfterMount
    }
    #expect(
        replayRequested,
        "hybrid primary output is advanced by terminal.bytes, so input recovery must request replay instead of waiting on advisory render-grid frames"
    )
    collector.unmount()
}

@MainActor
@Test func alternateRenderGridPinsGridAndSuppressesRawBytes() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 3,
        text: "alt",
        activeScreen: .alternate
    ))
    let altDelivered = try await pollUntil { collector.lines.contains { $0.contains("alt") } }
    #expect(altDelivered, "alternate-screen frames must still render through authoritative render-grid replay")
    #expect(collector.viewportPolicies.last == .remoteGrid(columns: 16, rows: 4))

    let deliveredCount = collector.lines.count
    await transport.deliver(try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 3, text: "dup"))
    await transport.deliver(try renderGridEventFrame(surfaceID: "live-terminal", seq: 6, text: "primary"))
    let primaryDelivered = try await pollUntil { collector.lines.contains { $0.contains("primary") } }
    #expect(primaryDelivered)
    #expect(collector.lines.count == deliveredCount + 1)
    #expect(
        collector.lines.contains { $0.contains("dup") } == false,
        "raw bytes are suppressed while the authoritative screen is alternate"
    )
    collector.unmount()
}

@MainActor
@Test func staleAlternateRenderGridDoesNotSuppressPrimaryRawBytes() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 0, text: "raw-a"))
    let firstRawDelivered = try await pollUntil { collector.lines.contains { $0.contains("raw-a") } }
    #expect(firstRawDelivered)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 1,
        text: "stale-alt",
        activeScreen: .alternate
    ))
    await transport.deliver(try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 5, text: "raw-b"))
    let secondRawDelivered = try await pollUntil { collector.lines.contains { $0.contains("raw-b") } }
    #expect(secondRawDelivered, "a stale alternate render-grid frame must not flip active-screen state and suppress later primary bytes")
    #expect(collector.lines.contains { $0.contains("stale-alt") } == false)
    collector.unmount()
}

@MainActor
@Test func primaryRenderGridAfterAlternateClearsRemoteGrid() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 3,
        text: "alt",
        activeScreen: .alternate
    ))
    let altDelivered = try await pollUntil { collector.viewportPolicies.last == .remoteGrid(columns: 16, rows: 4) }
    #expect(altDelivered)

    await transport.deliver(try renderGridEventFrame(surfaceID: "live-terminal", seq: 6, text: "shell"))
    let primaryDelivered = try await pollUntil { collector.lines.contains { $0.contains("shell") } }
    #expect(primaryDelivered, "the first primary frame after alternate must restore the primary screen")
    #expect(collector.viewportPolicies.last == .natural)
    collector.unmount()
}

@MainActor
@Test func primaryDeltaAfterAlternateRequestsReplayInsteadOfPatchingAlternateScreen() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    let transport = try #require(box.get())

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 3,
        text: "alt",
        activeScreen: .alternate
    ))
    let altDelivered = try await pollUntil { collector.viewportPolicies.last == .remoteGrid(columns: 16, rows: 4) }
    #expect(altDelivered)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 6,
        text: "primary-delta",
        activeScreen: .primary,
        full: false
    ))
    let replayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountAfterMount
    }
    #expect(replayRequested, "a primary delta cannot switch the local surface out of alternate-screen mode; request a full replay instead")
    #expect(
        collector.lines.contains { $0.contains("primary-delta") } == false,
        "the alternate-to-primary transition must not be painted with a delta patch"
    )
    #expect(
        collector.viewportPolicies.last == .remoteGrid(columns: 16, rows: 4),
        "a primary delta must not clear the remote-grid pin before the full replay restores primary"
    )

    await transport.deliver(try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 7, text: "raw-after-delta"))
    await transport.deliver(try renderGridEventFrame(surfaceID: "live-terminal", seq: 8, text: "primary-full"))
    let fullPrimaryDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("primary-full") }
    }
    #expect(fullPrimaryDelivered)
    #expect(
        collector.lines.contains { $0.contains("raw-after-delta") } == false,
        "raw bytes must stay suppressed until a full primary restore switches the local surface out of alternate-screen mode"
    )
    #expect(collector.viewportPolicies.last == .natural)
    collector.unmount()
}

@MainActor
@Test func emptyPrimaryDeltaWhileAlternateRequestsOneReplayAndKeepsRemoteGridUntilFullRestore() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    let transport = try #require(box.get())

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 3,
        text: "alt",
        activeScreen: .alternate
    ))
    let altDelivered = try await pollUntil { collector.viewportPolicies.last == .remoteGrid(columns: 16, rows: 4) }
    #expect(altDelivered)

    await transport.deliver(try emptyRenderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 6,
        activeScreen: .primary
    ))
    await transport.deliver(try emptyRenderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 7,
        activeScreen: .primary
    ))
    let replayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountAfterMount
    }
    #expect(
        replayRequested,
        "an empty primary transition while alternate is active is ambiguous; request one full replay instead of dropping later primary bytes indefinitely"
    )
    let replayCountAfterRepeatedEmptyDelta = await router.count(of: "mobile.terminal.replay")
    #expect(
        replayCountAfterRepeatedEmptyDelta == replayCountAfterMount + 1,
        "repeated empty primary deltas must be bounded by the replay in-flight guard"
    )
    await transport.deliver(try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 8, text: "raw-before-full"))
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 9,
        text: "still-alt",
        activeScreen: .alternate
    ))
    let laterAltDelivered = try await pollUntil { collector.lines.contains { $0.contains("still-alt") } }
    #expect(laterAltDelivered)
    #expect(
        collector.viewportPolicies.last == .remoteGrid(columns: 16, rows: 4),
        "empty primary deltas while alternate is active must not flicker the surface back to natural sizing"
    )
    #expect(
        collector.lines.contains { $0.contains("raw-before-full") } == false,
        "raw bytes stay suppressed until a full primary replay restores the local surface"
    )

    await transport.deliver(try renderGridEventFrame(surfaceID: "live-terminal", seq: 10, text: "primary-full"))
    let fullPrimaryDelivered = try await pollUntil { collector.lines.contains { $0.contains("primary-full") } }
    #expect(fullPrimaryDelivered)
    #expect(collector.viewportPolicies.last == .natural)
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
    let event = try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 9,
        text: "still-alive",
        activeScreen: .alternate
    )
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
    let event = try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 11,
        text: "repaired",
        activeScreen: .alternate
    )
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

/// Regression: the repaired-subscription catch-up must supersede an in-flight
/// cold-attach replay for the same surface. `requestTerminalReplay` coalesces
/// (no-ops) while a replay is already in flight, so if the user types — and the
/// re-subscribe repairs a lost host registration — before the cold-attach
/// replay has completed, the repaired catch-up would otherwise be silently
/// dropped, leaving the surface behind the input response sequence with no
/// follow-up replay.
@MainActor
@Test func repairReplaySupersedesInFlightColdAttachReplay() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    // One post-gap frame; the superseding repair replay must deliver it.
    await router.setReplayFrames([
        (seq: 12, text: "repaired-input"),
    ])
    // Park the cold-attach (mount) replay so it is still in flight when the
    // repair fires, reproducing the race the fix guards against.
    await router.holdNextReplayResponses(count: 1)
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    // The cold-attach replay request leaves the phone but its response stays
    // parked, so the surface has no locally rendered sequence yet.
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink arms the cold-attach replay")

    // Lose the subscription, then type: the input reports the Mac advanced past
    // the (still-empty) local sequence while the cold-attach replay is in flight.
    await router.dropSubscription()
    await store.submitTerminalRawInput(Data("x".utf8), surfaceID: "live-terminal")

    // The repaired subscription must supersede the in-flight cold-attach replay
    // and issue a fresh catch-up replay rather than coalescing behind it.
    // Without the fix, requestTerminalReplay no-ops on the in-flight guard and
    // this second replay never leaves the phone.
    let replayedAfterRepair = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 2 }
    #expect(
        replayedAfterRepair,
        "repair must supersede the in-flight cold-attach replay, not coalesce the catch-up behind it"
    )
    let deliveredRepairReplay = try await pollUntil { collector.lines.contains { $0.contains("repaired-input") } }
    #expect(deliveredRepairReplay, "the superseding replay must deliver the post-gap frame to the mounted sink")
    collector.unmount()
    await router.releaseAllHeld()
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
