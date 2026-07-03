import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7202:
// a mirrored terminal in a multi-pane Mac workspace rendered adjacent rows'
// characters spliced into the same line on the phone, persistently.
//
// The producer grid is the Mac surface grid. The Mac normally caps it to
// min(phone viewport, pane size) via `mobile.terminal.viewport`, so output is
// authored for a grid the phone can render. When that cap is missing or stale
// (multi-pane layout churn, a lost viewport report round-trip), the Mac keeps
// streaming output authored for a grid LARGER than the phone's: absolute row
// addressing clamps rows beyond the local grid onto the bottom row, and
// over-wide rows wrap through autowrap — both splice adjacent rows' glyphs
// into one rendered row. Deltas repaint only changed rows, so the splice
// never self-heals.
//
// The phone can detect this divergence: every render-grid frame (including
// the advisory frames of the hybrid transport) carries the producer's
// columns×rows. These tests pin the recovery contract: output authored for a
// grid that exceeds this phone's reported viewport must be held behind a
// replay barrier instead of painted, the phone must re-assert its viewport
// report so the Mac re-caps the shared grid, and the mirror must repaint from
// the first fitting replay.

/// A live render-grid event frame with an explicit producer grid size.
private func renderGridEventFrame(
    surfaceID: String,
    seq: UInt64,
    columns: Int,
    rows: Int,
    text: String,
    full: Bool
) throws -> Data {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: columns,
        rows: rows,
        full: full,
        clearedRows: full ? [] : [0],
        rowSpans: [
            MobileTerminalRenderGridFrame.RowSpan(
                row: 0,
                column: 0,
                styleID: 0,
                text: text
            ),
        ]
    )
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "terminal.render_grid",
        "payload": try frame.jsonObject(),
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

/// A raw-bytes event without a sequence, so delivery never depends on the
/// byte-continuity counter (which differs before and after a replay barrier).
private func unsequencedTerminalBytesEventFrame(
    surfaceID: String,
    text: String
) throws -> Data {
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "terminal.bytes",
        "payload": [
            "surface_id": surfaceID,
            "data_b64": Data(text.utf8).base64EncodedString(),
        ],
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

@MainActor
@Test func oversizedRenderGridFrameHoldsOutputAndReassertsViewport() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    // Prove the mount-time replay barrier is down before the scenario starts.
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "pre-probe"
    ))
    let probeDelivered = try await pollUntil { collector.lines.contains { $0.contains("pre-probe") } }
    #expect(probeDelivered, "raw bytes must flow before the oversized frame arrives")

    // The phone's natural grid, as the surface view reports it on didResize.
    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    let viewportReportBaseline = await router.count(of: "mobile.terminal.viewport")
    let replayBaseline = await router.count(of: "mobile.terminal.replay")

    // Fitting replay responses model the Mac after it re-applied the phone's
    // viewport cap. Several are enqueued so the barrier's bounded follow-up
    // replays also resolve cleanly.
    let convergedFrames = try (0..<3).map { index in
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 40 + UInt64(index),
            columns: 20,
            rows: 6,
            full: true,
            rowSpans: [
                MobileTerminalRenderGridFrame.RowSpan(
                    row: 0,
                    column: 0,
                    styleID: 0,
                    text: "converged"
                ),
            ]
        )
    }
    await router.enqueueReplayRenderGridFrames(convergedFrames)

    // A multi-pane Mac pane grid the phone can never render faithfully: the
    // Mac lost this phone's viewport cap, so frames (and the raw bytes behind
    // them) are authored for 90x40 while the phone can only show 20x6.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 20,
        columns: 90,
        rows: 40,
        text: "oversized",
        full: false
    ))

    // The phone must re-assert its viewport report so the Mac re-caps the
    // shared grid, and re-arm an authoritative replay for the repaint.
    let sawViewportReassert = try await pollUntil {
        await router.count(of: "mobile.terminal.viewport") > viewportReportBaseline
    }
    #expect(
        sawViewportReassert,
        "an oversized producer grid must re-assert this phone's viewport report so the Mac re-caps the shared grid"
    )
    let sawRecoveryReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayBaseline
    }
    #expect(
        sawRecoveryReplay,
        "an oversized producer grid must arm an authoritative replay to repaint once the grid converges"
    )

    // Raw bytes authored for the larger Mac grid must be held: replayed into
    // the smaller local grid they clamp rows onto the bottom row and wrap
    // over-wide rows, splicing adjacent rows' characters (issue #7202).
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 9,
        text: "SPLICE-BYTES"
    ))
    _ = try await pollUntil(attempts: 30) { collector.lines.contains { $0.contains("SPLICE-BYTES") } }
    #expect(
        collector.lines.contains { $0.contains("SPLICE-BYTES") } == false,
        "raw bytes authored for a grid larger than the phone's viewport must be held behind the replay barrier, not spliced into the local grid"
    )

    // The recovery replay's fitting frame repaints the mirror.
    let convergedDelivered = try await pollUntil { collector.lines.contains { $0.contains("converged") } }
    #expect(
        convergedDelivered,
        "the recovery replay must repaint the mirror once the Mac grid fits the phone's viewport again"
    )

    // Live output resumes after convergence.
    await transport.deliver(try unsequencedTerminalBytesEventFrame(
        surfaceID: "live-terminal",
        text: "after-converge"
    ))
    let resumed = try await pollUntil { collector.lines.contains { $0.contains("after-converge") } }
    #expect(resumed, "live output must resume once the mirror reconverged")
    // Re-check after convergence: held bytes must be dropped outright, never
    // buffered and released once the barrier clears.
    #expect(
        collector.lines.contains { $0.contains("SPLICE-BYTES") } == false,
        "bytes held during divergence must not be replayed after the mirror reconverges"
    )
    collector.unmount()
}

@MainActor
@Test func oversizedReplayResponseKeepsRecoveryBarrierUntilConvergence() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "pre-probe"
    ))
    let probeDelivered = try await pollUntil { collector.lines.contains { $0.contains("pre-probe") } }
    #expect(probeDelivered, "raw bytes must flow before the oversized frame arrives")

    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    let replayBaseline = await router.count(of: "mobile.terminal.replay")

    // The Mac has not re-applied the cap when the recovery replay resolves:
    // the first replay response still carries the oversized grid. Only the
    // bounded retry afterwards returns a fitting frame.
    let stillOversized = try MobileTerminalRenderGridFrame(
        surfaceID: "live-terminal",
        stateSeq: 30,
        columns: 90,
        rows: 40,
        full: true,
        rowSpans: [
            MobileTerminalRenderGridFrame.RowSpan(row: 0, column: 0, styleID: 0, text: "still-oversized"),
        ]
    )
    let convergedFrames = try (0..<2).map { index in
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 40 + UInt64(index),
            columns: 20,
            rows: 6,
            full: true,
            rowSpans: [
                MobileTerminalRenderGridFrame.RowSpan(row: 0, column: 0, styleID: 0, text: "converged"),
            ]
        )
    }
    await router.enqueueReplayRenderGridFrames([stillOversized] + convergedFrames)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 20,
        columns: 90,
        rows: 40,
        text: "oversized",
        full: false
    ))

    // The recovery replay consumes the oversized response, then its bounded
    // retry must fetch again until a fitting frame repaints the mirror.
    let sawRetryReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayBaseline + 2
    }
    #expect(
        sawRetryReplay,
        "an oversized replay response must keep the recovery barrier alive and retry, not release the held stream"
    )
    let convergedDelivered = try await pollUntil { collector.lines.contains { $0.contains("converged") } }
    #expect(convergedDelivered, "the retried replay must repaint the mirror with the fitting frame")
    #expect(
        collector.lines.contains { $0.contains("still-oversized") } == false,
        "an oversized replay response must never paint"
    )

    // Live bytes sent while the barrier was polling must never splice through.
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 9,
        text: "SPLICE-BYTES"
    ))
    _ = try await pollUntil(attempts: 30) { collector.lines.contains { $0.contains("SPLICE-BYTES") } }
    #expect(
        collector.lines.contains { $0.contains("SPLICE-BYTES") } == false,
        "bytes for the diverged grid must stay held across an oversized replay response"
    )
    collector.unmount()
}

@MainActor
@Test func oversizedFrameDuringUnbarrieredReplayInstallsBarrier() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    // Park the mount-time cold-attach replay so it is still in flight (with no
    // barrier) when the oversized frame arrives.
    await router.holdNextReplayResponses(count: 1)
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let convergedFrames = try (0..<2).map { index in
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 40 + UInt64(index),
            columns: 20,
            rows: 6,
            full: true,
            rowSpans: [
                MobileTerminalRenderGridFrame.RowSpan(row: 0, column: 0, styleID: 0, text: "converged"),
            ]
        )
    }
    await router.enqueueReplayRenderGridFrames(convergedFrames)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 20,
        columns: 90,
        rows: 40,
        text: "oversized",
        full: false
    ))

    // The oversized frame must take over the parked unbarriered replay with a
    // real barrier, so bytes for the diverged grid are held immediately.
    let sawBarrierReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= 2
    }
    #expect(
        sawBarrierReplay,
        "an oversized frame during an in-flight unbarriered replay must install a barrier and arm its replay"
    )
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "SPLICE-BYTES"
    ))
    _ = try await pollUntil(attempts: 30) { collector.lines.contains { $0.contains("SPLICE-BYTES") } }
    #expect(
        collector.lines.contains { $0.contains("SPLICE-BYTES") } == false,
        "bytes must be held even while the mount-time replay is still in flight"
    )
    let convergedDelivered = try await pollUntil { collector.lines.contains { $0.contains("converged") } }
    #expect(convergedDelivered, "the barrier replay must repaint the mirror once the grid fits")

    await router.releaseAllHeld()
    collector.unmount()
}

@MainActor
@Test func oversizedReplayFallbackBytesAreWithheld() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "pre-probe"
    ))
    let probeDelivered = try await pollUntil { collector.lines.contains { $0.contains("pre-probe") } }
    #expect(probeDelivered, "raw bytes must flow before the oversized frame arrives")

    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    let replayBaseline = await router.count(of: "mobile.terminal.replay")

    // The recovery replay resolves as a legacy raw byte tail still authored
    // for the diverged Mac grid; only the retry returns a fitting frame.
    await router.enqueueReplayRawTail(text: "FALLBACK-SPLICE", columns: 90, rows: 40)
    let convergedFrames = try (0..<2).map { index in
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 40 + UInt64(index),
            columns: 20,
            rows: 6,
            full: true,
            rowSpans: [
                MobileTerminalRenderGridFrame.RowSpan(row: 0, column: 0, styleID: 0, text: "converged"),
            ]
        )
    }
    await router.enqueueReplayRenderGridFrames(convergedFrames)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 20,
        columns: 90,
        rows: 40,
        text: "oversized",
        full: false
    ))

    let sawRetryReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayBaseline + 2
    }
    #expect(
        sawRetryReplay,
        "an oversized fallback replay must be withheld and retried, not painted"
    )
    let convergedDelivered = try await pollUntil { collector.lines.contains { $0.contains("converged") } }
    #expect(convergedDelivered, "the retried replay must repaint the mirror with the fitting frame")
    #expect(
        collector.lines.contains { $0.contains("FALLBACK-SPLICE") } == false,
        "a snapshot/raw-tail replay authored for a grid larger than the phone's viewport must never paint"
    )
    collector.unmount()
}

@MainActor
@Test func emptyReplayResponseKeepsOversizedRecoveryAlive() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "pre-probe"
    ))
    let probeDelivered = try await pollUntil { collector.lines.contains { $0.contains("pre-probe") } }
    #expect(probeDelivered, "raw bytes must flow before the oversized frame arrives")

    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    let replayBaseline = await router.count(of: "mobile.terminal.replay")

    // The Mac has no replay payload at all on the first recovery attempt (its
    // render-grid export can legitimately fail); the withheld oversized frame
    // must still keep the barrier alive so the bounded retry converges.
    await router.enqueueEmptyReplayResponses(count: 1)
    let convergedFrames = try (0..<2).map { index in
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 40 + UInt64(index),
            columns: 20,
            rows: 6,
            full: true,
            rowSpans: [
                MobileTerminalRenderGridFrame.RowSpan(row: 0, column: 0, styleID: 0, text: "converged"),
            ]
        )
    }
    await router.enqueueReplayRenderGridFrames(convergedFrames)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 20,
        columns: 90,
        rows: 40,
        text: "oversized",
        full: false
    ))

    let sawRetryReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayBaseline + 2
    }
    #expect(
        sawRetryReplay,
        "an empty replay response must not release the oversized-grid recovery; the withheld frame keeps it retrying"
    )
    let convergedDelivered = try await pollUntil { collector.lines.contains { $0.contains("converged") } }
    #expect(convergedDelivered, "the retried replay must repaint the mirror with the fitting frame")

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 9,
        text: "SPLICE-BYTES"
    ))
    _ = try await pollUntil(attempts: 30) { collector.lines.contains { $0.contains("SPLICE-BYTES") } }
    #expect(
        collector.lines.contains { $0.contains("SPLICE-BYTES") } == false,
        "bytes for the diverged grid must stay held across an empty replay response"
    )
    collector.unmount()
}

@MainActor
@Test func fittingFrameAfterExhaustedRecoveryRearmsBarrierReplay() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "pre-probe"
    ))
    let probeDelivered = try await pollUntil { collector.lines.contains { $0.contains("pre-probe") } }
    #expect(probeDelivered, "raw bytes must flow before the oversized frame arrives")

    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    let replayBaseline = await router.count(of: "mobile.terminal.replay")

    // Every bounded retry is spent on still-diverged fallback responses
    // (initial replay + two retries), exhausting the barrier's budget while
    // the producer stays oversized.
    for _ in 0..<3 {
        await router.enqueueReplayRawTail(text: "FALLBACK-SPLICE", columns: 90, rows: 40)
    }
    let convergedFrames = try (0..<2).map { index in
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 40 + UInt64(index),
            columns: 20,
            rows: 6,
            full: true,
            rowSpans: [
                MobileTerminalRenderGridFrame.RowSpan(row: 0, column: 0, styleID: 0, text: "converged"),
            ]
        )
    }
    await router.enqueueReplayRenderGridFrames(convergedFrames)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 20,
        columns: 90,
        rows: 40,
        text: "oversized",
        full: false
    ))
    let sawExhaustion = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayBaseline + 3
    }
    #expect(sawExhaustion, "the recovery must spend its bounded retries on the diverged responses")

    // The Mac converges: a fitting live frame arrives while the exhausted
    // barrier is still holding the stream. It must re-arm the barrier replay
    // instead of being dropped forever.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 39,
        columns: 20,
        rows: 6,
        text: "fits-now",
        full: true
    ))
    let sawRearmReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayBaseline + 4
    }
    #expect(
        sawRearmReplay,
        "a fitting frame after retry exhaustion must restart the recovery barrier's replay, not wedge the held stream"
    )
    let convergedDelivered = try await pollUntil { collector.lines.contains { $0.contains("converged") } }
    #expect(convergedDelivered, "the restarted replay must repaint the mirror with the fitting frame")
    #expect(
        collector.lines.contains { $0.contains("FALLBACK-SPLICE") } == false,
        "diverged fallback responses must never paint"
    )

    // Live output resumes after the repaint.
    await transport.deliver(try unsequencedTerminalBytesEventFrame(
        surfaceID: "live-terminal",
        text: "after-converge"
    ))
    let resumed = try await pollUntil { collector.lines.contains { $0.contains("after-converge") } }
    #expect(resumed, "live output must resume once the mirror reconverged")
    collector.unmount()
}

@MainActor
@Test func rapidRedivergenceAfterReplayConvergenceReinstallsBarrier() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "pre-probe"
    ))
    let probeDelivered = try await pollUntil { collector.lines.contains { $0.contains("pre-probe") } }
    #expect(probeDelivered, "raw bytes must flow before the oversized frame arrives")

    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    let replayBaseline = await router.count(of: "mobile.terminal.replay")

    let convergedFrames = try (0..<3).map { index in
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 40 + UInt64(index),
            columns: 20,
            rows: 6,
            full: true,
            rowSpans: [
                MobileTerminalRenderGridFrame.RowSpan(row: 0, column: 0, styleID: 0, text: "converged"),
            ]
        )
    }
    await router.enqueueReplayRenderGridFrames(convergedFrames)

    // First divergence converges via the replay path (which does not run the
    // live fitting-frame ingest), leaving the recovery pacing timestamp warm.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 20,
        columns: 90,
        rows: 40,
        text: "oversized",
        full: false
    ))
    let firstConverged = try await pollUntil { collector.lines.contains { $0.contains("converged") } }
    #expect(firstConverged, "the first recovery must repaint the mirror")

    // The Mac diverges again within the pacing interval. The barrier must be
    // reinstalled immediately — pacing may skip the report/replay spam, never
    // the hold.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 50,
        columns: 90,
        rows: 40,
        text: "oversized-again",
        full: false
    ))
    let sawSecondRecoveryReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayBaseline + 2
    }
    #expect(
        sawSecondRecoveryReplay,
        "a second divergence within the pacing interval must reinstall the barrier and arm its replay"
    )
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 9,
        text: "SPLICE-BYTES"
    ))
    _ = try await pollUntil(attempts: 30) { collector.lines.contains { $0.contains("SPLICE-BYTES") } }
    #expect(
        collector.lines.contains { $0.contains("SPLICE-BYTES") } == false,
        "bytes for a rapid re-divergence must be held even while the recovery pacing is warm"
    )
    #expect(
        collector.lines.contains { $0.contains("oversized-again") } == false,
        "the re-diverged frame must never paint"
    )
    collector.unmount()
}

@MainActor
@Test func staleOversizedRenderGridFrameStillTriggersRecovery() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    // Raw bytes advance the delivered sequence past the frame's stateSeq,
    // exactly like continuous hybrid output outrunning the coalesced
    // render-grid emit.
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "pre-probe"
    ))
    let probeDelivered = try await pollUntil { collector.lines.contains { $0.contains("pre-probe") } }
    #expect(probeDelivered, "raw bytes must flow before the oversized frame arrives")

    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    let replayBaseline = await router.count(of: "mobile.terminal.replay")

    let convergedFrames = try (0..<2).map { index in
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 40 + UInt64(index),
            columns: 20,
            rows: 6,
            full: true,
            rowSpans: [
                MobileTerminalRenderGridFrame.RowSpan(row: 0, column: 0, styleID: 0, text: "converged"),
            ]
        )
    }
    await router.enqueueReplayRenderGridFrames(convergedFrames)

    // The oversized frame is STALE (stateSeq 5 < delivered 9): its grid
    // dimensions must still trigger the divergence recovery.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 5,
        columns: 90,
        rows: 40,
        text: "oversized",
        full: false
    ))
    let sawRecoveryReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayBaseline
    }
    #expect(
        sawRecoveryReplay,
        "a stale oversized frame is still a diverged-grid signal and must arm the recovery"
    )
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 9,
        text: "SPLICE-BYTES"
    ))
    _ = try await pollUntil(attempts: 30) { collector.lines.contains { $0.contains("SPLICE-BYTES") } }
    #expect(
        collector.lines.contains { $0.contains("SPLICE-BYTES") } == false,
        "bytes authored for the diverged grid must be held even when the divergence signal arrived on a stale frame"
    )
    let convergedDelivered = try await pollUntil { collector.lines.contains { $0.contains("converged") } }
    #expect(convergedDelivered, "the recovery replay must repaint the mirror once the grid fits")
    collector.unmount()
}

@MainActor
@Test func legacyHostWithoutViewportSupportKeepsTrustingProducerGrids() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    // A version-skewed Mac that streams render-grid but cannot honor
    // mobile.terminal.viewport caps: the guard must stay off, or withheld
    // output would freeze the mirror instead of rendering it the legacy way.
    await router.setCapabilities([
        "events.v1", "terminal.bytes.v1", "terminal.render_grid.v1", "terminal.replay.v1",
    ])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "pre-probe"
    ))
    let probeDelivered = try await pollUntil { collector.lines.contains { $0.contains("pre-probe") } }
    #expect(probeDelivered, "raw bytes must flow after mount")

    // The report is still recorded locally (and attempted), but the fixture
    // host answers without an effective grid, so viewport support stays
    // unconfirmed.
    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    let replayBaseline = await router.count(of: "mobile.terminal.replay")

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 20,
        columns: 90,
        rows: 40,
        text: "oversized",
        full: false
    ))
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 9,
        text: "legacy-bytes"
    ))
    let delivered = try await pollUntil { collector.lines.contains { $0.contains("legacy-bytes") } }
    #expect(
        delivered,
        "against a host without viewport support the stream must keep flowing (legacy behavior), not freeze behind a recovery barrier"
    )
    let replayCount = await router.count(of: "mobile.terminal.replay")
    #expect(
        replayCount == replayBaseline,
        "no oversized-grid recovery replay may be armed against a host that cannot honor viewport caps"
    )
    collector.unmount()
}

@MainActor
@Test func fittingFrameDuringInflightRecoveryKeepsRearmSignal() async throws {
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
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "pre-probe"
    ))
    let probeDelivered = try await pollUntil { collector.lines.contains { $0.contains("pre-probe") } }
    #expect(probeDelivered, "raw bytes must flow before the oversized frame arrives")

    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    let replayBaseline = await router.count(of: "mobile.terminal.replay")

    // The whole retry budget resolves to still-diverged fallbacks; only the
    // post-exhaustion re-arm reaches the fitting frames.
    for _ in 0..<3 {
        await router.enqueueReplayRawTail(text: "FALLBACK-SPLICE", columns: 90, rows: 40)
    }
    let convergedFrames = try (0..<2).map { index in
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 40 + UInt64(index),
            columns: 20,
            rows: 6,
            full: true,
            rowSpans: [
                MobileTerminalRenderGridFrame.RowSpan(row: 0, column: 0, styleID: 0, text: "converged"),
            ]
        )
    }
    await router.enqueueReplayRenderGridFrames(convergedFrames)

    // Park the recovery replay so a fitting frame deterministically arrives
    // while it is still in flight.
    await router.holdNextReplayResponses(count: 1)
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 20,
        columns: 90,
        rows: 40,
        text: "oversized",
        full: false
    ))
    let sawRecoveryReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayBaseline + 1
    }
    #expect(sawRecoveryReplay, "the oversized frame must arm the recovery replay")

    // A fitting frame lands while the recovery replay is parked. It must not
    // consume the re-arm signal.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 25,
        columns: 20,
        rows: 6,
        text: "fits-early",
        full: true
    ))

    // Release the parked replay; the budget then burns down on the diverged
    // fallbacks until exhaustion.
    await router.releaseAllHeld()
    let sawExhaustion = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayBaseline + 3
    }
    #expect(sawExhaustion, "the recovery must spend its bounded retries on the diverged responses")

    // The next fitting frame must still be able to re-arm the exhausted
    // barrier and repaint.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 39,
        columns: 20,
        rows: 6,
        text: "fits-later",
        full: true
    ))
    let sawRearmReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayBaseline + 4
    }
    #expect(
        sawRearmReplay,
        "a fitting frame observed mid-recovery must not erase the signal that lets a later fitting frame re-arm the exhausted barrier"
    )
    let convergedDelivered = try await pollUntil { collector.lines.contains { $0.contains("converged") } }
    #expect(convergedDelivered, "the re-armed replay must repaint the mirror")
    #expect(
        collector.lines.contains { $0.contains("FALLBACK-SPLICE") } == false,
        "diverged fallback responses must never paint"
    )
    collector.unmount()
}

@MainActor
@Test func replayOriginBarrierWithOversizedResponsesReassertsViewport() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "pre-probe"
    ))
    let probeDelivered = try await pollUntil { collector.lines.contains { $0.contains("pre-probe") } }
    #expect(probeDelivered, "raw bytes must flow after mount")

    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    let viewportBaseline = await router.count(of: "mobile.terminal.viewport")

    // The barrier originates from a plain self-heal replay (no oversized live
    // frame preceded it — an idle surface). Its response reveals the diverged
    // Mac grid; recovery must still re-assert this phone's viewport so the
    // Mac re-caps, or an idle surface wedges until some unrelated frame.
    await router.enqueueReplayRawTail(text: "FALLBACK-SPLICE", columns: 90, rows: 40)
    let convergedFrames = try (0..<2).map { index in
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 40 + UInt64(index),
            columns: 20,
            rows: 6,
            full: true,
            rowSpans: [
                MobileTerminalRenderGridFrame.RowSpan(row: 0, column: 0, styleID: 0, text: "converged"),
            ]
        )
    }
    await router.enqueueReplayRenderGridFrames(convergedFrames)

    store.terminalOutputNeedsReplay(surfaceID: "live-terminal")

    let sawReassert = try await pollUntil {
        await router.count(of: "mobile.terminal.viewport") > viewportBaseline
    }
    #expect(
        sawReassert,
        "an oversized replay response on a replay-origin barrier must re-assert the phone's viewport so the Mac re-caps"
    )
    let convergedDelivered = try await pollUntil { collector.lines.contains { $0.contains("converged") } }
    #expect(convergedDelivered, "the retried replay must repaint the mirror with the fitting frame")
    #expect(
        collector.lines.contains { $0.contains("FALLBACK-SPLICE") } == false,
        "diverged fallback responses must never paint"
    )
    collector.unmount()
}

@MainActor
@Test func fittingFrameObservedMidRecoveryRearmsAfterExhaustion() async throws {
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
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "pre-probe"
    ))
    let probeDelivered = try await pollUntil { collector.lines.contains { $0.contains("pre-probe") } }
    #expect(probeDelivered, "raw bytes must flow before the oversized frame arrives")

    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    let replayBaseline = await router.count(of: "mobile.terminal.replay")

    for _ in 0..<3 {
        await router.enqueueReplayRawTail(text: "FALLBACK-SPLICE", columns: 90, rows: 40)
    }
    let convergedFrames = try (0..<2).map { index in
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 40 + UInt64(index),
            columns: 20,
            rows: 6,
            full: true,
            rowSpans: [
                MobileTerminalRenderGridFrame.RowSpan(row: 0, column: 0, styleID: 0, text: "converged"),
            ]
        )
    }
    await router.enqueueReplayRenderGridFrames(convergedFrames)

    // Park the recovery replay so the terminal's single dimension-change
    // frame (an idle terminal emits exactly one) deterministically lands
    // while the replay is in flight.
    await router.holdNextReplayResponses(count: 1)
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 20,
        columns: 90,
        rows: 40,
        text: "oversized",
        full: false
    ))
    let sawRecoveryReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayBaseline + 1
    }
    #expect(sawRecoveryReplay, "the oversized frame must arm the recovery replay")

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 25,
        columns: 20,
        rows: 6,
        text: "fits-once",
        full: true
    ))

    // The parked replay resumes and the whole retry budget resolves to
    // diverged fallbacks. No further frame will ever arrive; the observed
    // fitting frame must re-arm the barrier by itself.
    await router.releaseAllHeld()
    let sawRearmReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayBaseline + 4
    }
    #expect(
        sawRearmReplay,
        "the fitting frame observed mid-recovery must re-arm the exhausted barrier without any further frame"
    )
    let convergedDelivered = try await pollUntil { collector.lines.contains { $0.contains("converged") } }
    #expect(convergedDelivered, "the re-armed replay must repaint the mirror")
    #expect(
        collector.lines.contains { $0.contains("FALLBACK-SPLICE") } == false,
        "diverged fallback responses must never paint"
    )
    collector.unmount()
}

@MainActor
@Test func viewportConfirmationDoesNotLeakAcrossClientSwap() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    // A legacy host: no terminal.viewport.v1 capability, but the viewport RPC
    // itself answers with an effective grid, so the first client confirms
    // support empirically.
    await router.setCapabilities([
        "events.v1", "terminal.bytes.v1", "terminal.render_grid.v1", "terminal.replay.v1",
    ])
    await router.setViewportResponseGrid(columns: 20, rows: 6)
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")

    // The first client confirms viewport support via a successful round-trip.
    let echoed = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 20, rows: 6)
    #expect(echoed != nil, "the fixture host must echo an effective grid to confirm support")

    // A connection swap (e.g. promoting another Mac's client to foreground)
    // replaces the remote client. The old client's empirical confirmation
    // must not arm the oversized-grid guard against the new connection.
    try installFreshLivenessRemoteClient(on: store, router: router, box: box, clock: clock)

    await router.enqueueReplayRawTail(text: "LEGACY-TAIL", columns: 90, rows: 40)
    store.terminalOutputNeedsReplay(surfaceID: "live-terminal")
    let tailDelivered = try await pollUntil { collector.lines.contains { $0.contains("LEGACY-TAIL") } }
    #expect(
        tailDelivered,
        "after a client swap the prior connection's viewport confirmation must not withhold output on a host without the capability"
    )
    collector.unmount()
}

@MainActor
@Test func fittingRenderGridFramesKeepOutputFlowing() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "pre-probe"
    ))
    let probeDelivered = try await pollUntil { collector.lines.contains { $0.contains("pre-probe") } }
    #expect(probeDelivered, "raw bytes must flow after mount")

    _ = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 40, rows: 12)
    let viewportReportBaseline = await router.count(of: "mobile.terminal.viewport")

    // A producer grid within the phone's viewport (the letterboxed multi-pane
    // steady state) must not trip the divergence recovery.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 20,
        columns: 16,
        rows: 4,
        text: "fits",
        full: false
    ))
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 9,
        text: "still-flowing"
    ))
    let delivered = try await pollUntil { collector.lines.contains { $0.contains("still-flowing") } }
    #expect(delivered, "output for a fitting producer grid must keep flowing")

    let reportCount = await router.count(of: "mobile.terminal.viewport")
    #expect(
        reportCount == viewportReportBaseline,
        "a fitting producer grid must not trigger viewport re-assertion"
    )
    collector.unmount()
}
