import Foundation
import Testing
@testable import CmuxMobileShell

/// A follow-up replay barrier clears the delivered high-water sequence, so a
/// buffered render-grid frame from BEFORE the barrier could otherwise pass the
/// staleness guard, bypass the barrier as a "live baseline", cancel the
/// in-flight authoritative replay, and let newer deltas composite over stale
/// state. The pre-barrier stale floor must reject it while a current full
/// frame still establishes the recovery baseline.
@MainActor
@Test func staleBufferedFullFrameCannotBypassFollowUpBarrier() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    await router.holdNextReplayResponses(count: 2)
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    var lines: [String] = []
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)

    // A live full frame bypasses the cold-attach barrier and establishes the
    // baseline at seq 50; hold its chunk unprocessed so the ack is pending.
    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 50,
        text: "live-full-during-cold",
        full: true
    ))
    let baselineChunk = try #require(await iterator.next())
    lines.append(String(decoding: baselineChunk.data, as: UTF8.self))
    #expect(lines.last?.contains("live-full-during-cold") == true)

    // A delta lands before the ack, so processing the full frame arms the
    // follow-up barrier: the baseline moves into the pre-barrier stale floor
    // while the follow-up replay (held) is in flight.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 55,
        text: "delta-before-ack",
        full: false
    ))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: baselineChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    #expect(store.terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] == 50)

    // Out-of-order arrival of a full frame captured BEFORE the baseline: it
    // must not bypass the follow-up barrier or paint over the pending replay.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 10,
        text: "stale-buffered-full",
        full: true
    ))

    // A current full frame is still the legitimate live recovery baseline.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 70,
        text: "fresh-full",
        full: true
    ))
    let freshChunk = try #require(await iterator.next())
    lines.append(String(decoding: freshChunk.data, as: UTF8.self))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: freshChunk.streamToken)

    #expect(lines.last?.contains("fresh-full") == true)
    #expect(
        !lines.contains { $0.contains("stale-buffered-full") },
        "a pre-barrier full frame must not paint over the pending follow-up replay"
    )
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 70)
    #expect(store.terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] == nil)

    await router.releaseAllHeld()
}

/// The stale floor exists to bridge one recovery window, not to wedge the
/// stream: an accepted authoritative replay re-bases the floor even when the
/// host's sequence counter restarted lower (surface recreate), so live frames
/// from the new sequence epoch flow again afterwards.
@MainActor
@Test func replayAfterHostSequenceResetRebasesStaleFloor() async throws {
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
    }
    #expect(coldReplaySettledEmpty)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 900,
        text: "old-epoch-baseline",
        full: true
    ))
    let baselineDelivered = try await pollUntil {
        store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 900
    }
    #expect(baselineDelivered)

    // The host recreated the surface: its authoritative replay answers from a
    // sequence epoch far below the stashed floor and must still win.
    await router.enqueueReplayRenderGrid(try renderGridFrame(
        surfaceID: surfaceID,
        seq: 3,
        text: "new-epoch-replay",
        full: true
    ))
    store.terminalOutputNeedsReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let replayRebasedFloor = try await pollUntil {
        collector.lines.contains { $0.contains("new-epoch-replay") }
    }
    #expect(replayRebasedFloor, "an accepted authoritative replay must win over the stale floor")

    // With the floor re-based to the replay's epoch, live frames flow again.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "new-epoch-live",
        full: true
    ))
    let newEpochDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("new-epoch-live") }
    }
    #expect(newEpochDelivered, "a re-based floor must let the new sequence epoch flow")
    #expect(store.terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] == nil)
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 4)

    collector.unmount()
    await router.releaseAllHeld()
}

/// The stale floor guards the byte channel too: a buffered pre-barrier
/// `terminal.bytes` chunk (hybrid transport) is provably content the
/// barrier-era replay already covers, so it must not count as dropped output
/// needing follow-up coverage while the barrier is armed — and once the
/// barrier releases without delivering, the floor is restored as the live
/// baseline so stale chunks stay rejected and contiguous output flows.
@MainActor
@Test func staleBufferedByteChunkCannotReleaseStaleFloor() async throws {
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
    }
    #expect(coldReplaySettledEmpty)

    let transport = try #require(box.get())
    // 19 bytes starting at seq 900: the delivered end lands at 919.
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 900,
        text: "live-bytes-baseline"
    ))
    let baselineDelivered = try await pollUntil {
        store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 919
    }
    #expect(baselineDelivered)

    // Recovery barrier armed with its replay held: the baseline moves into
    // the stale floor.
    await router.holdNextReplayResponses()
    store.terminalOutputNeedsReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    #expect(store.terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] == 919)

    // Wholly below the floor: the barrier-era replay already covers it, so it
    // must not even count as dropped output demanding a follow-up replay.
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 100,
        text: "stale-buffered-bytes"
    ))
    let staleByteChunkIgnored = try await pollUntil {
        store.terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] == 919
            && store.terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] == nil
    }
    #expect(staleByteChunkIgnored, "a pre-barrier byte chunk must not count as dropped live output")

    // The barrier releases without delivering: the floor is restored as the
    // live baseline (the surface still shows exactly that content).
    await router.releaseAllHeld()
    let baselineRestored = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 919
            && store.terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(baselineRestored, "releasing a barrier without delivery must restore the floor as the baseline")

    // Stale chunks stay rejected against the restored baseline; contiguous
    // output resumes from it.
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 100,
        text: "stale-buffered-bytes"
    ))
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 919,
        text: "fresh-live-bytes"
    ))
    let freshDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("fresh-live-bytes") }
    }
    #expect(freshDelivered)
    #expect(
        !collector.lines.contains { $0.contains("stale-buffered-bytes") },
        "a pre-barrier byte chunk must not repaint stale output"
    )

    collector.unmount()
}

/// The reviewer-reported stall: a live full frame establishes the baseline, a
/// delta before its ack arms a follow-up replay, and the follow-up FAILS.
/// Releasing that barrier used to erase the delivered baseline and exhaust the
/// missing-baseline budget, so every later delta was dropped as baseline-less
/// until an incidental full frame arrived. The release must restore the
/// pre-barrier baseline so deltas keep flowing.
@MainActor
@Test func failedFollowUpReplayRestoresLiveBaseline() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    await router.holdNextReplayResponses()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    var lines: [String] = []
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 50,
        text: "live-full-baseline",
        full: true
    ))
    let baselineChunk = try #require(await iterator.next())
    lines.append(String(decoding: baselineChunk.data, as: UTF8.self))
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 50)

    // A delta before the ack forces a follow-up replay; every attempt fails
    // (initial follow-up plus both retries).
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 55,
        text: "delta-before-ack",
        full: false
    ))
    await router.failNextReplay(count: 3)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: baselineChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 4)

    // The failed follow-up must hand the pre-barrier baseline back instead of
    // leaving the surface baseline-less with an exhausted replay budget.
    let baselineRestored = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 50
    }
    #expect(baselineRestored, "a failed follow-up replay must restore the live baseline")
    #expect(store.terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] == nil)

    // Deltas keep flowing against the restored baseline.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 60,
        text: "delta-after-recovery",
        full: false
    ))
    let deltaChunk = try #require(await iterator.next())
    lines.append(String(decoding: deltaChunk.data, as: UTF8.self))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: deltaChunk.streamToken)
    #expect(lines.last?.contains("delta-after-recovery") == true)
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 60)

    await router.releaseAllHeld()
}
