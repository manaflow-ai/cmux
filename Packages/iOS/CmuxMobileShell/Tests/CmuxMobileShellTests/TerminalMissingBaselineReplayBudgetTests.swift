import Testing
@testable import CmuxMobileShell

@MainActor
@Test func missingBaselineEmptyReplaysRespectRetryBudget() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(coldReplaySettledEmpty)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "partial-starts-first-empty-baseline-replay",
        full: false
    ))
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let firstMissingBaselineReplaySettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
    }
    #expect(firstMissingBaselineReplaySettled)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 5,
        text: "partial-starts-second-empty-baseline-replay",
        full: false
    ))
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 3)
    let secondMissingBaselineReplaySettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
    }
    #expect(secondMissingBaselineReplaySettled)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 6,
        text: "partial-after-empty-baseline-budget",
        full: false
    ))
    #expect(
        await router.count(of: "mobile.terminal.replay") == 3,
        "empty missing-baseline replays must keep the retry budget exhausted"
    )
    #expect(!collector.lines.contains { $0.contains("partial-after-empty-baseline-budget") })

    collector.unmount()
}

@MainActor
@Test func staleReplayAfterLiveFullFrameDoesNotDiscardDroppedPartials() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(coldReplaySettledEmpty)

    await router.holdNextReplayResponses()
    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "partial-starts-held-baseline-replay",
        full: false
    ))
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 10,
        text: "live-full-takes-over",
        full: true
    ))
    let fullChunk = try #require(await iterator.next())
    #expect(String(decoding: fullChunk.data, as: UTF8.self).contains("live-full-takes-over"))

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 11,
        text: "partial-dropped-before-full-ack",
        full: false
    ))
    await router.enqueueReplayPayload(text: "stale-held-replay", sequence: 5)
    await router.releaseAllHeld()
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: fullChunk.streamToken)

    let followUpRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 3,
        recordIssueOnTimeout: false
    )
    #expect(followUpRequested, "dropped partials after a live full-frame takeover still require a follow-up replay")
}

@MainActor
@Test func hybridPrimaryPartialWithoutBaselineDoesNotBlockRawBytes() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(coldReplaySettledEmpty)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "hybrid-primary-advisory",
        full: false
    ))
    #expect(
        await router.count(of: "mobile.terminal.replay") == 1,
        "hybrid primary partials are advisory and must not start baseline replay"
    )

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 5,
        text: "raw-after-hybrid-primary-partial"
    ))
    let rawDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("raw-after-hybrid-primary-partial") }
    }
    #expect(rawDelivered)

    collector.unmount()
}

@MainActor
@Test func hybridAlternatePartialAfterPrimaryBytesStillWaitsForBaseline() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(coldReplaySettledEmpty)

    let transport = try #require(box.get())
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 3,
        text: "primary-raw-before-alt"
    ))
    let rawDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("primary-raw-before-alt") }
    }
    #expect(rawDelivered)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 100,
        text: "alternate-partial-without-baseline",
        activeScreen: .alternate,
        full: false
    ))
    let replayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 2,
        recordIssueOnTimeout: false
    )
    #expect(replayRequested, "primary raw bytes are not an alternate render-grid baseline")
    #expect(!collector.lines.contains { $0.contains("alternate-partial-without-baseline") })

    let firstAlternateReplaySettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
    }
    #expect(firstAlternateReplaySettled)
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 101,
        text: "second-alternate-partial-without-baseline",
        activeScreen: .alternate,
        full: false
    ))
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 3)
    let secondAlternateReplaySettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
    }
    #expect(secondAlternateReplaySettled)
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 102,
        text: "third-alternate-partial-without-baseline",
        activeScreen: .alternate,
        full: false
    ))
    #expect(
        await router.count(of: "mobile.terminal.replay") == 3,
        "primary raw bytes must not reset the alternate missing-baseline replay budget"
    )

    collector.unmount()
}

@MainActor
@Test func replayedFullAlternateRenderGridEstablishesBaselineForDeltas() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    await router.enqueueReplayRenderGrid(try renderGridFrame(
        surfaceID: "live-terminal",
        seq: 1,
        text: "alternate-replay-baseline",
        activeScreen: .alternate,
        full: true
    ))
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let replayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("alternate-replay-baseline") }
    }
    #expect(replayDelivered)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 2,
        text: "alternate-delta-after-replay-baseline",
        activeScreen: .alternate,
        full: false
    ))
    let deltaDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("alternate-delta-after-replay-baseline") }
    }
    #expect(deltaDelivered)
    #expect(
        await router.count(of: "mobile.terminal.replay") == 1,
        "a full alternate replay is a baseline for later alternate deltas"
    )

    collector.unmount()
}
