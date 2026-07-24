import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

// Regression coverage for stale render-grid replay suppression
// (https://github.com/manaflow-ai/cmux/issues/7159): a replay response
// that is older than (or equal-sequence with) output the phone already
// painted must not overwrite a newer live grid, while genuinely required
// same-sequence recovery replays must still apply.
// Shared fixtures live in MobileShellRenderGridLivenessTestSupport.swift.

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
    // Merged cold-attach contract: a partial delta with no delivered baseline
    // is gated instead of painting onto the blank surface, so it must not
    // advance the delivered sequence underneath the held replay.
    let partialGated = try await pollUntil {
        store.deliveredTerminalByteEndSeqBySurfaceID["live-terminal"] == nil
            && !collector.lines.contains { $0.contains("partial-live-delta") }
    }
    #expect(partialGated, "a baseline-less partial delta must be gated, not painted")

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
        "a same-sequence replay is still required when live output was only a gated partial delta"
    )
    #expect(
        !collector.lines.contains { $0.contains("partial-live-delta") },
        "the gated partial must never paint before the authoritative snapshot"
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
