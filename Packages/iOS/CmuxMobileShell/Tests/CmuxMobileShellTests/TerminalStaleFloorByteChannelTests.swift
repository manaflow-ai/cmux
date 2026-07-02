import Foundation
import Testing
@testable import CmuxMobileShell

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

/// A compatibility host can answer a replay with a raw byte tail that carries
/// no sequence. Such a tail is not authoritative enough to re-base the stale
/// floor — the floor must survive until the tail's ack restores it as the
/// baseline, so buffered pre-barrier chunks stay rejected afterwards.
@MainActor
@Test func seqlessReplayTailPreservesStaleFloorUntilAck() async throws {
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

    // Self-heal replay answered by a seq-less raw tail: its ack must restore
    // the stashed floor as the baseline.
    await router.enqueueReplayTexts(["seqless-raw-tail"])
    store.terminalOutputNeedsReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let tailDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("seqless-raw-tail") }
    }
    #expect(tailDelivered)
    let baselineRestoredFromFloor = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 919
            && store.terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(
        baselineRestoredFromFloor,
        "a seq-less replay tail must leave the floor for the ack to restore as the baseline"
    )

    // Buffered pre-barrier bytes stay rejected; contiguous output flows.
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
    #expect(!collector.lines.contains { $0.contains("stale-buffered-bytes") })

    collector.unmount()
}
