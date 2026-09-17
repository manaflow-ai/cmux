import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

private func chainGateFrame(
    surfaceID: String,
    stateSeq: UInt64,
    revision: UInt64,
    full: Bool,
    baseRevision: UInt64? = nil,
    text: String
) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: stateSeq,
        renderEpoch: "epoch-1",
        renderRevision: revision,
        columns: 20,
        rows: 2,
        full: full,
        clearedRows: full ? [] : [0],
        rowSpans: [.init(row: 0, column: 0, styleID: 0, text: text)],
        deltaBaseRenderRevision: baseRevision
    )
}

// A delta names the revision of the frame it was diffed against. When the
// delivered chain does not end at that frame (a delta was dropped by the
// typing fence, shed by the host queue, or lost in transit), painting the
// delta would leave silently stale rows: the delivery gate must request a
// full replay instead.
@MainActor
@Test func renderGridDeltaAfterMissedFrameRequestsReplayInsteadOfPainting() async throws {
    let surfaceID = "terminal-chain-gate"
    let store = MobileShellComposite.preview()
    store.selectedTerminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
    store.terminalOutputTransport = .renderGrid
    var outputIterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

    let full = try chainGateFrame(
        surfaceID: surfaceID, stateSeq: 1, revision: 5, full: true, text: "baseline"
    )
    store.deliverAuthoritativeTerminalRenderGrid(full, source: "event")
    let fullChunk = try #require(await outputIterator.next())
    #expect(try #require(String(data: fullChunk.data, encoding: .utf8)).contains("baseline"))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: fullChunk.streamToken)

    let chainedDelta = try chainGateFrame(
        surfaceID: surfaceID, stateSeq: 2, revision: 6, full: false, baseRevision: 5, text: "chained"
    )
    store.deliverAuthoritativeTerminalRenderGrid(chainedDelta, source: "event")
    let deltaChunk = try #require(await outputIterator.next())
    #expect(try #require(String(data: deltaChunk.data, encoding: .utf8)).contains("chained"))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: deltaChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    // Revision 7 was emitted by the producer but never delivered here; the
    // next delta chains from it and can no longer patch this grid. The gate
    // requests a replay instead of painting (the preview store has no remote
    // client, so the resulting barrier resolves immediately; the durable
    // proof is that the gapped frame was never recorded as delivered).
    let gappedDelta = try chainGateFrame(
        surfaceID: surfaceID, stateSeq: 4, revision: 8, full: false, baseRevision: 7, text: "gapped"
    )
    store.deliverAuthoritativeTerminalRenderGrid(gappedDelta, source: "event")

    #expect(
        store.terminalRenderGridRevisionContinuityBySurfaceID[surfaceID]?.renderRevision == 6
    )
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] != 4)

    // A follow-up full frame re-bases the chain and paints again.
    let recoveryFull = try chainGateFrame(
        surfaceID: surfaceID, stateSeq: 5, revision: 9, full: true, text: "recovered"
    )
    store.deliverAuthoritativeTerminalRenderGrid(recoveryFull, source: "event")
    let recoveredChunk = try #require(await outputIterator.next())
    #expect(try #require(String(data: recoveredChunk.data, encoding: .utf8)).contains("recovered"))
    #expect(
        store.terminalRenderGridRevisionContinuityBySurfaceID[surfaceID]?.renderRevision == 9
    )
}

// Render-grid continuity advances when a frame is admitted, before the
// renderer acknowledges the chunk. A valid delta queued behind an in-flight
// frame must retain the admission decision made against its own predecessor;
// recomputing it at yield time would see the newer shared cursor and route the
// delta through an unnecessary verified replay.
@MainActor
@Test func queuedRenderGridDeltaRetainsAdmissionReplayPolicy() async throws {
    let surfaceID = "terminal-queued-policy"
    let store = MobileShellComposite.preview()
    store.selectedTerminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
    store.terminalOutputTransport = .renderGrid
    store.supportedHostCapabilities = [
        MobileShellComposite.terminalVerifiedReplayCapability,
        MobileShellComposite.terminalScreenAnchorCapability,
    ]
    var outputIterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

    var baseline = try chainGateFrame(
        surfaceID: surfaceID,
        stateSeq: 1,
        revision: 1,
        full: true,
        text: "baseline"
    )
    baseline.anchor = .screen
    baseline.historyRows = 0
    store.deliverAuthoritativeTerminalRenderGrid(baseline, source: "event")
    let baselineChunk = try #require(await outputIterator.next())
    #expect(baselineChunk.requiresVerifiedReplay)

    var firstDelta = try chainGateFrame(
        surfaceID: surfaceID,
        stateSeq: 2,
        revision: 2,
        full: false,
        baseRevision: 1,
        text: "first-delta"
    )
    firstDelta.anchor = .screen
    firstDelta.historyRows = 0
    firstDelta.deltaBaseHistoryRows = 0
    store.deliverAuthoritativeTerminalRenderGrid(firstDelta, source: "event")

    var secondDelta = try chainGateFrame(
        surfaceID: surfaceID,
        stateSeq: 3,
        revision: 3,
        full: false,
        baseRevision: 2,
        text: "second-delta"
    )
    secondDelta.anchor = .screen
    secondDelta.historyRows = 0
    secondDelta.deltaBaseHistoryRows = 0
    store.deliverAuthoritativeTerminalRenderGrid(secondDelta, source: "event")

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount == 2)
    #expect(store.terminalRenderGridRevisionContinuityBySurfaceID[surfaceID]?.renderRevision == 3)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: baselineChunk.streamToken)
    let queuedChunk = try #require(await outputIterator.next())
    #expect(queuedChunk.sourceRenderGridFrame?.renderRevision == 2)
    #expect(!queuedChunk.requiresVerifiedReplay)
}

// Legacy producers emit deltas without a base revision; the history chain
// remains their only guard and delivery must keep painting them.
@MainActor
@Test func renderGridLegacyDeltaWithoutBaseRevisionStillPaints() async throws {
    let surfaceID = "terminal-chain-legacy"
    let store = MobileShellComposite.preview()
    store.selectedTerminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
    store.terminalOutputTransport = .renderGrid
    var outputIterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

    let full = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 1,
        columns: 20,
        rows: 2,
        full: true,
        rowSpans: [.init(row: 0, column: 0, styleID: 0, text: "legacy-baseline")]
    )
    store.deliverAuthoritativeTerminalRenderGrid(full, source: "event")
    let fullChunk = try #require(await outputIterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: fullChunk.streamToken)

    let legacyDelta = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 2,
        columns: 20,
        rows: 2,
        full: false,
        clearedRows: [0],
        rowSpans: [.init(row: 0, column: 0, styleID: 0, text: "legacy-delta")]
    )
    store.deliverAuthoritativeTerminalRenderGrid(legacyDelta, source: "event")
    let deltaChunk = try #require(await outputIterator.next())
    #expect(try #require(String(data: deltaChunk.data, encoding: .utf8)).contains("legacy-delta"))
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
}
