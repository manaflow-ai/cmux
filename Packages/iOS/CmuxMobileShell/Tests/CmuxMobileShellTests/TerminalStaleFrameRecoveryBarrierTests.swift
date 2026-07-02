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
        seq: 900,
        text: "old-epoch-baseline",
        full: true
    ))
    let baselineChunk = try #require(await iterator.next())
    lines.append(String(decoding: baselineChunk.data, as: UTF8.self))
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 900)

    // A delta before the ack arms the follow-up barrier, stashing the
    // old-epoch floor (900). The host meanwhile recreated the surface, so the
    // follow-up replay answers from a sequence epoch far below that floor —
    // and must still win.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 905,
        text: "delta-before-ack",
        full: false
    ))
    await router.enqueueReplayRenderGrid(try renderGridFrame(
        surfaceID: surfaceID,
        seq: 3,
        text: "new-epoch-replay",
        full: true
    ))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: baselineChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let replayChunk = try #require(await iterator.next())
    lines.append(String(decoding: replayChunk.data, as: UTF8.self))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
    #expect(lines.last?.contains("new-epoch-replay") == true)

    // With the floor re-based to the replay's epoch, live frames flow again.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "new-epoch-live",
        full: true
    ))
    let liveChunk = try #require(await iterator.next())
    lines.append(String(decoding: liveChunk.data, as: UTF8.self))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: liveChunk.streamToken)
    #expect(lines.last?.contains("new-epoch-live") == true)
    #expect(store.terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] == nil)
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 4)

    await router.releaseAllHeld()
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

/// The alternate-screen twin of the baseline restore: a follow-up replay
/// barrier only pauses delivery while the surface keeps showing the alternate
/// content, so the alternate baseline flag must survive a barrier that
/// releases empty — otherwise the next alternate delta is treated as
/// missing-baseline and a hybrid TUI stalls right after recovery.
@MainActor
@Test func emptyFollowUpReplayPreservesAlternateBaseline() async throws {
    let router = LivenessHostRouter()
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
        text: "alt-baseline",
        activeScreen: .alternate,
        full: true
    ))
    let baselineChunk = try #require(await iterator.next())
    lines.append(String(decoding: baselineChunk.data, as: UTF8.self))
    #expect(store.terminalAlternateRenderGridBaselineSurfaceIDs.contains(surfaceID))

    // An alternate delta lands before the ack, forcing a follow-up replay
    // that answers empty over the intact surface: both the sequence baseline
    // and the alternate flag must survive its release.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 55,
        text: "alt-delta-before-ack",
        activeScreen: .alternate,
        full: false
    ))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: baselineChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let alternateBaselinePreserved = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 50
            && store.terminalAlternateRenderGridBaselineSurfaceIDs.contains(surfaceID)
    }
    #expect(
        alternateBaselinePreserved,
        "an empty follow-up replay must not erase the alternate-screen baseline"
    )

    // Alternate deltas keep flowing instead of being gated as baseline-less.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 60,
        text: "alt-delta-after-heal",
        activeScreen: .alternate,
        full: false
    ))
    let deltaChunk = try #require(await iterator.next())
    lines.append(String(decoding: deltaChunk.data, as: UTF8.self))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: deltaChunk.streamToken)
    #expect(lines.last?.contains("alt-delta-after-heal") == true)

    await router.releaseAllHeld()
}

/// Render-grid-only alternate gating is keyed to the DELIVERED alternate
/// baseline, not the speculatively tracked screen: after a primary baseline,
/// alternate deltas stay gated through failed/empty baseline replays (a delta
/// VT patch cannot switch screens), the replay budget survives the restored
/// sequence baseline, and only a delivered full alternate frame opens the
/// alternate screen for deltas.
@MainActor
@Test func alternateDeltasStayGatedUntilFullAlternateFrameDelivers() async throws {
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
        seq: 50,
        text: "primary-baseline",
        full: true
    ))
    let primaryBaselineDelivered = try await pollUntil {
        store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 50
    }
    #expect(primaryBaselineDelivered)

    // The session enters the alternate screen host-side. Each alternate delta
    // is gated (no delivered alternate baseline) and arbitrated by an
    // empty-answering baseline replay whose release restores the sequence
    // baseline — which must NOT reopen the gate or reset the replay budget.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 55,
        text: "alt-delta-one",
        activeScreen: .alternate,
        full: false
    ))
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let firstArbitrationSettled = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 50
    }
    #expect(firstArbitrationSettled)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 60,
        text: "alt-delta-two",
        activeScreen: .alternate,
        full: false
    ))
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 3)
    let secondArbitrationSettled = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(secondArbitrationSettled)

    // Budget exhausted: a third gated delta must not request another replay.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 65,
        text: "alt-delta-three",
        activeScreen: .alternate,
        full: false
    ))
    // A delivered full alternate frame is the causal recovery signal; once it
    // lands, the earlier deltas' fate is sealed.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 70,
        text: "alt-full-restore",
        activeScreen: .alternate,
        full: true
    ))
    let altFullDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("alt-full-restore") }
    }
    #expect(altFullDelivered)
    #expect(
        await router.count(of: "mobile.terminal.replay") == 3,
        "gated alternate deltas must respect the baseline replay budget"
    )
    #expect(
        !collector.lines.contains { $0.contains("alt-delta-one") || $0.contains("alt-delta-two") || $0.contains("alt-delta-three") },
        "alternate deltas must never paint before a full alternate frame delivers"
    )

    // With the alternate baseline delivered, alternate deltas flow.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 75,
        text: "alt-delta-after-full",
        activeScreen: .alternate,
        full: false
    ))
    let altDeltaDeliveredAfterFull = try await pollUntil {
        collector.lines.contains { $0.contains("alt-delta-after-full") }
    }
    #expect(altDeltaDeliveredAfterFull)

    collector.unmount()
}
