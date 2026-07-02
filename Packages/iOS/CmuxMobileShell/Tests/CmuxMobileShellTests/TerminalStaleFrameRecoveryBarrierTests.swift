import Testing
@testable import CmuxMobileShell

/// A recovery replay barrier clears the delivered high-water sequence, so a
/// buffered render-grid frame from BEFORE the barrier could otherwise pass the
/// staleness guard, bypass the barrier as a "live baseline", cancel the
/// in-flight authoritative replay, and let newer deltas composite over stale
/// state. The pre-barrier stale floor must reject it while a current full
/// frame still establishes the recovery baseline.
@MainActor
@Test func staleBufferedFullFrameCannotBypassRecoveryBarrier() async throws {
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
        text: "live-baseline",
        full: true
    ))
    let baselineDelivered = try await pollUntil {
        store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 50
    }
    #expect(baselineDelivered)

    // Recovery: the reset barrier snapshots seq 50 as the stale floor, and the
    // recovery replay answers empty, so no fresh baseline exists afterwards.
    store.terminalOutputNeedsReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let recoveryReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(recoveryReplaySettledEmpty)

    // A partial arrives with no baseline, arming the missing-baseline barrier
    // with its authoritative replay held in flight.
    await router.holdNextReplayResponses()
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 55,
        text: "partial-during-recovery",
        full: false
    ))
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 3)

    // Out-of-order arrival of a full frame captured BEFORE the seq-50 baseline.
    // It must not bypass the recovery barrier, paint, or become the baseline.
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
    let freshDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("fresh-full") }
    }
    #expect(freshDelivered, "a current full frame must establish the recovery baseline")
    #expect(
        !collector.lines.contains { $0.contains("stale-buffered-full") },
        "a pre-barrier full frame must not paint over the pending recovery replay"
    )
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 70)

    collector.unmount()
    await router.releaseAllHeld()
}

/// The stale floor exists to bridge one recovery window, not to wedge the
/// stream: a frame rejected purely by the floor (no live baseline) nudges the
/// budget-capped baseline replay, and the accepted authoritative replay
/// re-bases the floor — even when the host's sequence counter restarted lower
/// (surface recreate) — so live frames from the new epoch flow again.
@MainActor
@Test func replayAfterHostSequenceResetReleasesStaleFloor() async throws {
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

    // Recovery stashes the old-epoch floor (900) and the recovery replay
    // answers empty: no live baseline remains, only the floor.
    store.terminalOutputNeedsReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let recoveryReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(recoveryReplaySettledEmpty)

    // The host recreated the surface: its authoritative state restarted at
    // seq 3. The first new-epoch live frame is below the stale floor, so it
    // must not paint — but it must nudge the baseline replay that arbitrates.
    await router.enqueueReplayRenderGrid(try renderGridFrame(
        surfaceID: surfaceID,
        seq: 3,
        text: "new-epoch-replay",
        full: true
    ))
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "new-epoch-live-blocked",
        full: true
    ))
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 3)
    let replayRebasedFloor = try await pollUntil {
        collector.lines.contains { $0.contains("new-epoch-replay") }
    }
    #expect(replayRebasedFloor, "the floor-rejected frame must trigger the arbitrating replay")

    // With the floor re-based to the replay's epoch, live frames flow again.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 5,
        text: "new-epoch-live",
        full: true
    ))
    let newEpochDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("new-epoch-live") }
    }
    #expect(newEpochDelivered, "a re-based floor must let the new sequence epoch flow")
    #expect(
        !collector.lines.contains { $0.contains("new-epoch-live-blocked") },
        "the below-floor frame itself must not paint"
    )
    #expect(store.terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] == nil)

    collector.unmount()
    await router.releaseAllHeld()
}

/// The stale floor guards the byte channel too: a buffered pre-barrier
/// `terminal.bytes` chunk (hybrid transport) must neither repaint stale
/// output nor release the floor — only catching up to the floor releases it.
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
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 900,
        text: "live-bytes-baseline"
    ))
    let baselineDelivered = try await pollUntil {
        (store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0) > 900
    }
    #expect(baselineDelivered)

    store.terminalOutputNeedsReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let recoveryReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(recoveryReplaySettledEmpty)

    // Wholly below the floor: covered by the barrier-era replay, must vanish.
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 100,
        text: "stale-buffered-bytes"
    ))

    // Genuinely new output releases the floor by catching up past it.
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 2000,
        text: "fresh-live-bytes"
    ))
    let freshDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("fresh-live-bytes") }
    }
    #expect(freshDelivered)
    #expect(
        !collector.lines.contains { $0.contains("stale-buffered-bytes") },
        "a pre-barrier byte chunk must not repaint stale output after recovery"
    )
    #expect(store.terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] == nil)

    collector.unmount()
    await router.releaseAllHeld()
}
