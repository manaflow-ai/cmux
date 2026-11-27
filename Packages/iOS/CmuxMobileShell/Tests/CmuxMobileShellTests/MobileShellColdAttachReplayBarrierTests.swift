import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

// Regression coverage for the iOS cold-attach terminal replay barrier
// (https://github.com/manaflow-ai/cmux/issues/7159): output that arrives
// while the cold-attach replay is still in flight must be held behind the
// replay barrier (never painted ahead of the replay base), including when
// the surface is mounted before the connection or capabilities resolve.
// Shared fixtures live in MobileShellRenderGridLivenessTestSupport.swift.

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
    let barrierCleared = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID["live-terminal"] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains("live-terminal")
    }
    #expect(barrierCleared, "the deferred cold replay barrier must fail open or settle")
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 7,
        text: "post-deferred-full",
        columns: 32,
        full: true
    ))
    let postDeferredDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("post-deferred-full") }
    }
    #expect(postDeferredDelivered, "live output must resume after the deferred cold replay barrier clears")
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
@Test func coldAttachReplayMountedBeforeConnectionStillReplaysOnHostWithoutReplayCapability() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1"])
    await router.enqueueReplayRenderGridFrames([
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 5,
            columns: 24,
            rows: 4,
            full: true,
            rowSpans: [
                .init(row: 0, column: 0, text: "legacy-base"),
            ]
        ),
    ])
    let box = TransportBox()
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now }
    )
    let store = MobileShellComposite.preview(runtime: runtime)
    store.signIn()

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
        !store.supportedHostCapabilities.isEmpty
    }
    #expect(capabilitiesResolved, "host capabilities must resolve after connecting")

    let coldReplayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= 1
    }
    #expect(
        coldReplayRequested,
        "a sink mounted before connection must still get its cold replay when the host lacks terminal.replay.v1"
    )
    let baseDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("legacy-base") }
    }
    #expect(
        baseDelivered,
        "the fallback cold replay must paint the terminal on hosts without the replay barrier capability"
    )
    collector.unmount()
}
