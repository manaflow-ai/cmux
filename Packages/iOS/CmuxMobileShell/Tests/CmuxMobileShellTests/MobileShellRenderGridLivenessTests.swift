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
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing subscribe buffering"
    )

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
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing primary render-grid delivery"
    )
    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(surfaceID: "live-terminal", seq: 3, text: "grid-only"))
    let gridDelivered = try await pollUntil { collector.lines.contains { $0.contains("grid-only") } }
    #expect(gridDelivered, "render-grid-only hosts must keep painting primary render-grid frames")
    collector.unmount()
}

@MainActor
@Test func coldAttachReplayBarrierHoldsRenderGridDeltaUntilBaseApplies() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let collector = OutputCollector()
    let replayCapabilityResolved = try await pollUntil {
        store.supportedHostCapabilities.contains("terminal.replay.v1")
    }
    #expect(replayCapabilityResolved, "the host replay capability must be known before mounting")
    await router.holdNextReplayResponses()
    collector.mount(store: store, surfaceID: "live-terminal")
    let coldReplayRequested = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(coldReplayRequested, "mounting a sink must request the cold replay")
    let transport = try #require(box.get())

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 6,
        text: "racing-delta",
        columns: 16,
        full: false
    ))
    let preBaseRendered = try await pollUntil(attempts: 60) {
        collector.lines.contains { $0.contains("racing-delta") }
    }
    #expect(
        preBaseRendered == false,
        "a cold-attach render-grid delta must not paint into an empty local terminal before the authoritative replay base applies"
    )

    await router.enqueueReplayRenderGridFrames([
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 5,
            columns: 24,
            rows: 4,
            full: true,
            rowSpans: [
                .init(row: 0, column: 0, text: "authoritative-base"),
            ]
        ),
    ])
    await router.releaseAllHeld()

    let baseDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("authoritative-base") }
    }
    #expect(
        baseDelivered,
        "the cold replay base must still apply even when newer live output raced it"
    )
    let followUpSettled = try await pollUntil { await router.replayResponsesServed() >= 2 }
    #expect(followUpSettled, "dropped racing output should trigger and settle one catch-up replay")

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 7,
        text: "post-settle",
        columns: 16
    ))
    let postSettleDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("post-settle") }
    }
    #expect(postSettleDelivered, "live render-grid output must resume after the cold barrier settles")
    collector.unmount()
}

@MainActor
@Test func coldAttachReplayBarrierHoldsHybridRawBytesUntilBaseApplies() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let collector = OutputCollector()
    let replayCapabilityResolved = try await pollUntil {
        store.supportedHostCapabilities.contains("terminal.replay.v1")
    }
    #expect(replayCapabilityResolved, "the host replay capability must be known before mounting")
    await router.holdNextReplayResponses()
    collector.mount(store: store, surfaceID: "live-terminal")
    let coldReplayRequested = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(coldReplayRequested, "mounting a sink must request the cold replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 6,
        text: "racing-raw"
    ))
    let preBaseRendered = try await pollUntil(attempts: 60) {
        collector.lines.contains { $0.contains("racing-raw") }
    }
    #expect(
        preBaseRendered == false,
        "cold-attach raw bytes must not paint into an empty local terminal before the authoritative replay base applies"
    )

    await router.enqueueReplayRenderGridFrames([
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 5,
            columns: 24,
            rows: 4,
            full: true,
            rowSpans: [
                .init(row: 0, column: 0, text: "authoritative-base"),
            ]
        ),
    ])
    await router.releaseAllHeld()

    let baseDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("authoritative-base") }
    }
    #expect(
        baseDelivered,
        "the cold replay base must still apply even when newer raw bytes raced it"
    )
    let followUpSettled = try await pollUntil { await router.replayResponsesServed() >= 2 }
    #expect(followUpSettled, "dropped racing output should trigger and settle one catch-up replay")

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 5,
        text: "post-raw"
    ))
    let postSettleDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("post-raw") }
    }
    #expect(postSettleDelivered, "live raw output must resume after the cold barrier settles")
    collector.unmount()
}

@MainActor
@Test func coldAttachReplayMountedBeforeConnectionUpgradesToBarrierWhenCapabilitiesResolve() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    await router.holdNextReplayResponses()
    let box = TransportBox()
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now }
    )
    let store = MobileShellComposite.preview(runtime: runtime)
    store.signIn()
    defer {
        Task { await router.releaseAllHeld() }
    }

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let replayBeforeConnection = try await pollUntil(attempts: 60) {
        await router.count(of: "mobile.terminal.replay") > 0
    }
    #expect(
        replayBeforeConnection == false,
        "mounting before a remote client exists must not send an inert replay request"
    )

    let connected = await store.connectPairingURL(try attachURL(for: makeTicket(clock: clock)))
    #expect(connected, "scripted connect must succeed")
    let capabilitiesResolved = try await pollUntil {
        store.supportedHostCapabilities.contains("terminal.replay.v1")
    }
    #expect(capabilitiesResolved, "host capabilities must resolve after connecting")
    let coldReplayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= 1
    }
    #expect(
        coldReplayRequested,
        "a sink mounted before connection must be upgraded to a barriered replay once replay capability is known"
    )
    let transport = try #require(box.get())

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 6,
        text: "early-delta",
        columns: 16,
        full: false
    ))
    let preBaseRendered = try await pollUntil(attempts: 60) {
        collector.lines.contains { $0.contains("early-delta") }
    }
    #expect(
        preBaseRendered == false,
        "the deferred cold replay upgrade must hold racing deltas until the base replay applies"
    )

    await router.enqueueReplayRenderGridFrames([
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 5,
            columns: 24,
            rows: 4,
            full: true,
            rowSpans: [
                .init(row: 0, column: 0, text: "deferred-base"),
            ]
        ),
    ])
    await router.releaseAllHeld()

    let baseDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("deferred-base") }
    }
    #expect(
        baseDelivered,
        "the deferred cold replay base must apply after capabilities resolve"
    )
    let followUpSettled = try await pollUntil { await router.replayResponsesServed() >= 2 }
    #expect(followUpSettled, "dropped pre-base output should still trigger and settle one catch-up replay")
    collector.unmount()
}

@MainActor
@Test func renderGridReplayAtSameSeqDoesNotOverwriteNewerLiveGrid() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let coldReplayRequested = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(coldReplayRequested, "mounting a sink must request the cold replay")
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before arming the held non-cold replay"
    )
    let transport = try #require(box.get())

    await router.holdNextReplayResponses()
    let replayCountBeforeHeldReplay = await router.count(of: "mobile.terminal.replay")
    store.requestTerminalReplay(surfaceID: "live-terminal")
    let heldReplayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountBeforeHeldReplay
    }
    #expect(heldReplayRequested, "the non-cold replay must be requested before the live grid paints")

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 5,
        text: "fresh-wide-grid",
        columns: 16
    ))
    let freshDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("fresh-wide-grid") }
    }
    #expect(freshDelivered, "the live render-grid frame must paint before the held replay resolves")

    await router.enqueueReplayRenderGridFrames([
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 5,
            columns: 4,
            rows: 4,
            full: true,
            rowSpans: [
                .init(row: 0, column: 0, text: "old!"),
            ]
        ),
    ])
    await router.releaseAllHeld()

    let staleDelivered = try await pollUntil(attempts: 60) {
        collector.lines.contains { $0.contains("old!") }
    }
    #expect(
        staleDelivered == false,
        "a replay captured at an older grid width must not overwrite an already-delivered live frame at the same state sequence"
    )
    collector.unmount()
}

@MainActor
@Test func hybridPrimaryFullGridAllowsSameSeqReplayBeforeRawBytesCatchUp() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let coldReplayRequested = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(coldReplayRequested, "mounting a sink must request the cold replay")
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before arming the held non-cold replay"
    )
    let transport = try #require(box.get())

    await router.holdNextReplayResponses()
    let replayCountBeforeHeldReplay = await router.count(of: "mobile.terminal.replay")
    store.requestTerminalReplay(surfaceID: "live-terminal")
    let heldReplayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountBeforeHeldReplay
    }
    #expect(heldReplayRequested, "the non-cold replay must be requested before the advisory grid")

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 5,
        text: "fresh-wide-grid",
        columns: 16
    ))
    let advisoryProcessed = try await pollUntil {
        collector.viewportPolicies.last == .natural
    }
    #expect(advisoryProcessed, "primary render-grid events are advisory in default hybrid mode")
    #expect(
        collector.lines.contains { $0.contains("fresh-wide-grid") } == false,
        "the hybrid advisory path must not advance raw-byte delivery"
    )

    await router.enqueueReplayRenderGridFrames([
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 5,
            columns: 4,
            rows: 4,
            full: true,
            rowSpans: [
                .init(row: 0, column: 0, text: "old!"),
            ]
        ),
    ])
    await router.releaseAllHeld()

    let replayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("old!") }
    }
    #expect(
        replayDelivered,
        "an advisory primary full grid does not paint terminal content, so the same-sequence replay must seed the local terminal until raw bytes catch up"
    )
    collector.unmount()
}

@MainActor
@Test func hybridPrimaryFullGridStillSuppressesSameSeqReplayAfterRawBytesCatchUp() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let coldReplayRequested = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(coldReplayRequested, "mounting a sink must request the cold replay")
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before arming the held non-cold replay"
    )
    let transport = try #require(box.get())

    await router.holdNextReplayResponses()
    let replayCountBeforeHeldReplay = await router.count(of: "mobile.terminal.replay")
    store.requestTerminalReplay(surfaceID: "live-terminal")
    let heldReplayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountBeforeHeldReplay
    }
    #expect(heldReplayRequested, "the non-cold replay must be requested before raw bytes catch up")

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 5,
        text: "fresh-wide-grid",
        columns: 16
    ))
    let advisoryProcessed = try await pollUntil {
        collector.viewportPolicies.last == .natural
    }
    #expect(advisoryProcessed, "primary render-grid events are advisory in default hybrid mode")

    await transport.deliver(try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 0, text: "raw5!"))
    let rawDelivered = try await pollUntil { collector.lines.contains { $0.contains("raw5!") } }
    #expect(rawDelivered, "same-sequence raw bytes must still paint in hybrid primary mode")

    await router.enqueueReplayRenderGridFrames([
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 5,
            columns: 4,
            rows: 4,
            full: true,
            rowSpans: [
                .init(row: 0, column: 0, text: "old!"),
            ]
        ),
    ])
    await router.releaseAllHeld()

    let staleDelivered = try await pollUntil(attempts: 60) {
        collector.lines.contains { $0.contains("old!") }
    }
    #expect(
        staleDelivered == false,
        "same-sequence raw bytes must not clear the advisory full-grid freshness marker before a held replay resolves"
    )
    collector.unmount()
}

@MainActor
@Test func hybridPrimaryNewerFullGridSuppressesOlderStaleReplay() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let coldReplayRequested = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(coldReplayRequested, "mounting a sink must request the cold replay")
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before arming the held non-cold replay"
    )
    let transport = try #require(box.get())

    await router.holdNextReplayResponses()
    let replayCountBeforeHeldReplay = await router.count(of: "mobile.terminal.replay")
    store.requestTerminalReplay(surfaceID: "live-terminal")
    let heldReplayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountBeforeHeldReplay
    }
    #expect(heldReplayRequested, "the non-cold replay must be requested before raw bytes cover the older seq")

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 6,
        text: "newer-grid",
        columns: 16
    ))
    let advisoryProcessed = try await pollUntil {
        collector.viewportPolicies.last == .natural
    }
    #expect(advisoryProcessed, "the newer primary full grid is advisory in default hybrid mode")

    await transport.deliver(try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 0, text: "raw5!"))
    let rawDelivered = try await pollUntil { collector.lines.contains { $0.contains("raw5!") } }
    #expect(rawDelivered, "raw bytes covering the older replay seq must paint before the held replay resolves")

    await router.enqueueReplayRenderGridFrames([
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 5,
            columns: 16,
            rows: 4,
            full: true,
            rowSpans: [
                .init(row: 0, column: 0, text: "older-replay"),
            ]
        ),
    ])
    await router.releaseAllHeld()

    let staleDelivered = try await pollUntil(attempts: 60) {
        collector.lines.contains { $0.contains("older-replay") }
    }
    #expect(
        staleDelivered == false,
        "a newer hybrid primary full-grid observation plus raw byte coverage must stale an older held replay"
    )
    collector.unmount()
}

@MainActor
@Test func hybridPrimaryFullGridDuringReplayBarrierDoesNotSuppressBarrierReplay() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must request the cold replay")
    let mountReplayCompleted = try await pollUntil { await router.replayResponsesServed() >= 1 }
    #expect(mountReplayCompleted, "the cold replay response must complete before arming the barrier hold")
    let transport = try #require(box.get())

    await router.holdNextReplayResponses()
    let replayCountBeforeBarrier = await router.count(of: "mobile.terminal.replay")
    store.terminalOutputNeedsReplay(surfaceID: "live-terminal")
    let barrierReplayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountBeforeBarrier
    }
    #expect(barrierReplayRequested, "manual replay must create a replay barrier request")

    let viewportPolicyCountBeforeAdvisory = collector.viewportPolicies.count
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 5,
        text: "barrier-advisory",
        columns: 16
    ))
    let advisoryDeliveredDuringBarrier = try await pollUntil(attempts: 60) {
        collector.viewportPolicies.count > viewportPolicyCountBeforeAdvisory
    }
    #expect(
        advisoryDeliveredDuringBarrier == false,
        "advisory output is dropped while the replay barrier waits for the authoritative replay"
    )

    await router.enqueueReplayRenderGridFrames([
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 5,
            columns: 16,
            rows: 4,
            full: true,
            rowSpans: [
                .init(row: 0, column: 0, text: "barrier-replay"),
            ]
        ),
    ])
    await router.releaseAllHeld()

    let replayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("barrier-replay") }
    }
    #expect(
        replayDelivered,
        "a same-seq barrier replay must still apply after an advisory full grid that was dropped by the barrier"
    )
    collector.unmount()
}

@MainActor
@Test func renderGridReplayAtSameSeqStillAppliesAfterPartialLiveDelta() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let coldReplayRequested = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(coldReplayRequested, "mounting a sink must request the cold replay")
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before arming the held non-cold replay"
    )
    let transport = try #require(box.get())

    await router.holdNextReplayResponses()
    let replayCountBeforeHeldReplay = await router.count(of: "mobile.terminal.replay")
    store.requestTerminalReplay(surfaceID: "live-terminal")
    let heldReplayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountBeforeHeldReplay
    }
    #expect(heldReplayRequested, "the non-cold replay must be requested before the partial delta")

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 5,
        text: "partial-live-delta",
        columns: 24,
        full: false
    ))
    let partialDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("partial-live-delta") }
    }
    #expect(partialDelivered, "a live partial render-grid delta may arrive before the held replay")

    await router.enqueueReplayRenderGridFrames([
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 5,
            columns: 24,
            rows: 4,
            full: true,
            rowSpans: [
                .init(row: 0, column: 0, text: "authoritative-snapshot"),
            ]
        ),
    ])
    await router.releaseAllHeld()

    let replayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("authoritative-snapshot") }
    }
    #expect(
        replayDelivered,
        "a same-sequence replay is still required when the only delivered live output was a partial delta"
    )
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
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing advisory primary render-grid"
    )
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
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing input recovery"
    )
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
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing alternate render-grid delivery"
    )
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
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing stale alternate suppression"
    )
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
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing alternate-to-primary restore"
    )
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
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing primary-delta recovery"
    )
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
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing empty primary-delta recovery"
    )
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
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing healthy idle liveness"
    )

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
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing repaired subscription replay"
    )

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

@MainActor
@Test func livenessRepairDeliversSameSeqReplayAfterExistingFullGrid() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink arms the cold-attach replay")
    let mountReplayCompleted = try await pollUntil { await router.replayResponsesServed() >= 1 }
    #expect(mountReplayCompleted, "the cold replay response must complete before scripting the repair replay")
    let transport = try #require(box.get())

    await transport.deliver(try renderGridEventFrame(surfaceID: "live-terminal", seq: 5, text: "stale-grid"))
    let staleGridDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("stale-grid") }
    }
    #expect(staleGridDelivered, "the pre-gap full render grid must establish the local delivered seq")

    await router.dropSubscription()
    await router.enqueueReplayRenderGridFrames([
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 5,
            columns: 16,
            rows: 4,
            full: true,
            rowSpans: [
                .init(row: 0, column: 0, text: "fresh-grid"),
            ]
        ),
    ])
    let replayCountBeforeRepair = await router.count(of: "mobile.terminal.replay")
    clock.advance(by: 10)
    store.debugRunRenderGridLivenessCheckForTesting()

    let replayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountBeforeRepair
    }
    #expect(replayRequested, "repairing a lost subscription must request a catch-up replay")
    let freshGridDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("fresh-grid") }
    }
    #expect(
        freshGridDelivered,
        "a same-sequence recovery replay requested after an existing full grid must still repaint"
    )
    collector.unmount()
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
