import Testing
@testable import CMUXMobileCore

private func chainFrame(
    revision: UInt64,
    epoch: String = "epoch-1",
    full: Bool = false,
    baseRevision: UInt64? = nil,
    columns: Int = 8,
    rows: Int = 2
) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: revision,
        renderEpoch: epoch,
        renderRevision: revision,
        columns: columns,
        rows: rows,
        full: full,
        clearedRows: full ? [] : [0],
        rowSpans: [.init(row: 0, column: 0, text: "row")],
        deltaBaseRenderRevision: baseRevision
    )
}

@Test func revisionContinuityRejectsDeltaAcrossDimensionChange() throws {
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 7, full: true, columns: 80, rows: 24)
    )
    // The producer reused the revision chain while the phone resized. The
    // delta's absolute rows address a different grid and must be replayed.
    let delta = try chainFrame(
        revision: 8,
        baseRevision: 7,
        columns: 40,
        rows: 12
    )

    #expect(!MobileTerminalRenderGridRevisionContinuity.admits(delta, delivered: delivered))
}

@Test func revisionContinuityAdmitsChainedDelta() throws {
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 7, full: true)
    )
    let delta = try chainFrame(revision: 8, baseRevision: 7)

    #expect(MobileTerminalRenderGridRevisionContinuity.admits(delta, delivered: delivered))
}

@Test func revisionContinuityRejectsDeltaAfterMissedFrame() throws {
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 7, full: true)
    )
    // Frame 8 was dropped (typing fence, shed, transport loss); frame 9 was
    // diffed against 8 and can no longer patch the delivered grid.
    let delta = try chainFrame(revision: 9, baseRevision: 8)

    #expect(!MobileTerminalRenderGridRevisionContinuity.admits(delta, delivered: delivered))
}

@Test func revisionContinuityRejectsDeltaFromRetiredEpoch() throws {
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 7, epoch: "epoch-2", full: true)
    )
    let delta = try chainFrame(revision: 8, epoch: "epoch-1", baseRevision: 7)

    #expect(!MobileTerminalRenderGridRevisionContinuity.admits(delta, delivered: delivered))
}

@Test func revisionContinuityRejectsDeltaWithoutDeliveredBaseline() throws {
    let delta = try chainFrame(revision: 8, baseRevision: 7)

    #expect(!MobileTerminalRenderGridRevisionContinuity.admits(delta, delivered: nil))
}

@Test func revisionContinuityAdmitsLegacyDeltaWithoutBase() throws {
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 7, full: true)
    )
    let legacyDelta = try chainFrame(revision: 9, baseRevision: nil)

    #expect(MobileTerminalRenderGridRevisionContinuity.admits(legacyDelta, delivered: delivered))
}

@Test func revisionContinuityAdmitsFullFrameUnconditionally() throws {
    let full = try chainFrame(revision: 9, full: true)

    #expect(MobileTerminalRenderGridRevisionContinuity.admits(full, delivered: nil))
}

@Test func revisionContinuityRejectsNonAdvancingDelta() throws {
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        renderEpoch: "epoch-1",
        renderRevision: 7
    )
    // A producer diffs against an older capture, never the same or a newer
    // one; a frame violating that is malformed and must not patch.
    let equalRevision = try chainFrame(revision: 7, baseRevision: 7)
    let regressedRevision = try chainFrame(revision: 6, baseRevision: 7)

    #expect(!MobileTerminalRenderGridRevisionContinuity.admits(equalRevision, delivered: delivered))
    #expect(!MobileTerminalRenderGridRevisionContinuity.admits(regressedRevision, delivered: delivered))
}

@Test func revisionContinuityRejectsDeltaWithUnknownDeliveredDimensions() throws {
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        renderEpoch: "epoch-1",
        renderRevision: 7
    )
    let delta = try chainFrame(revision: 8, baseRevision: 7)

    #expect(!MobileTerminalRenderGridRevisionContinuity.admits(delta, delivered: delivered))
}

@Test func revisionContinuityRejectsEpochlessDeltaAcrossDimensionChange() throws {
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 7, full: true, columns: 80, rows: 24)
    )
    let delta = try chainFrame(
        revision: 8,
        epoch: "",
        baseRevision: 7,
        columns: 40,
        rows: 12
    )

    #expect(!MobileTerminalRenderGridRevisionContinuity.admits(delta, delivered: delivered))
}

@Test func revisionContinuityRejectsEpochlessDeltaWithStaleBase() throws {
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 8, full: true)
    )
    let delta = try chainFrame(revision: 9, epoch: "", baseRevision: 7)

    #expect(!MobileTerminalRenderGridRevisionContinuity.admits(delta, delivered: delivered))
}

@Test func revisionContinuityRejectsEpochlessDeltaWithoutBaseline() throws {
    // A base revision without an epoch still needs a delivered shape. Without
    // that baseline, a resize could make absolute row spans unsafe to patch.
    let epochlessDelta = try chainFrame(revision: 8, epoch: "", baseRevision: 7)

    #expect(!MobileTerminalRenderGridRevisionContinuity.admits(epochlessDelta, delivered: nil))
}

@Test func revisionContinuityRoundTripsThroughCoding() throws {
    let delta = try chainFrame(revision: 8, baseRevision: 7)

    let decoded = try MobileTerminalRenderGridFrame.decodeJSONObject(delta.jsonObject())

    #expect(decoded.deltaBaseRenderRevision == 7)
    #expect(decoded.renderRevision == 8)
}

@Test func revisionContinuityTreatsLegacyPayloadAsBaseless() throws {
    var payload = try chainFrame(revision: 8, baseRevision: 7).jsonObject()
    payload.removeValue(forKey: "delta_base_render_revision")

    let decoded = try MobileTerminalRenderGridFrame.decodeJSONObject(payload)

    #expect(decoded.deltaBaseRenderRevision == nil)
    #expect(MobileTerminalRenderGridRevisionContinuity.admits(
        decoded,
        delivered: MobileTerminalRenderGridRevisionContinuity(renderEpoch: "epoch-1", renderRevision: 3)
    ))
}

// MARK: - Stale-versus-corruption classification
//
// A replay baseline races the delta stream over a high-RTT transport: frames
// emitted before the replay's capture are still in flight when the baseline
// lands. Their content is superseded by construction (revisions are monotonic
// within an epoch), so they are stale, not corruption. Answering them with a
// replay resets the chain again while the next in-flight frames arrive, a
// livelock measured at one full replay per round trip in the field
// (https://github.com/manaflow-ai/cmux/issues/13474).

@Test func classifyMarksPreBaselineInFlightDeltaStale() throws {
    // Replay baseline delivered at revision 12; a delta diffed 9-against-8
    // was already in flight when it landed.
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 12, full: true)
    )
    let inFlight = try chainFrame(revision: 9, baseRevision: 8)

    #expect(MobileTerminalRenderGridRevisionContinuity.classify(inFlight, delivered: delivered) == .stale)
}

@Test func classifyMarksStaleDeltaStaleEvenAcrossShapeMismatch() throws {
    // The stale frame predates a resize too. Its shape is irrelevant: it is
    // superseded either way and must not be escalated to a replay.
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 12, full: true, columns: 80, rows: 24)
    )
    let inFlight = try chainFrame(revision: 9, baseRevision: 8, columns: 40, rows: 12)

    #expect(MobileTerminalRenderGridRevisionContinuity.classify(inFlight, delivered: delivered) == .stale)
}

@Test func classifyMarksPreBaselineFullFrameStale() throws {
    // An older FULL frame arriving after a newer baseline would regress the
    // display and then break the chain on the next live delta. It is equally
    // superseded.
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 12, full: true)
    )
    let oldFull = try chainFrame(revision: 9, full: true)

    #expect(MobileTerminalRenderGridRevisionContinuity.classify(oldFull, delivered: delivered) == .stale)
}

@Test func classifyKeepsGapAheadAsChainBreak() throws {
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 7, full: true)
    )
    // Frame 8 was genuinely missed; 9 cannot patch and is NOT stale.
    let ahead = try chainFrame(revision: 9, baseRevision: 8)

    #expect(MobileTerminalRenderGridRevisionContinuity.classify(ahead, delivered: delivered) == .chainBreak)
}

@Test func classifyKeepsCrossEpochDeltaAsChainBreak() throws {
    // Epochs restart the revision sequence (surface recreate), so ordering
    // across epochs is undefined: fail closed exactly as before.
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 12, epoch: "epoch-2", full: true)
    )
    let crossEpoch = try chainFrame(revision: 9, epoch: "epoch-1", baseRevision: 8)

    #expect(MobileTerminalRenderGridRevisionContinuity.classify(crossEpoch, delivered: delivered) == .chainBreak)
}

@Test func classifyAdmitsCrossEpochFullFrame() throws {
    // A full frame from a new epoch is the legitimate baseline after a
    // surface recreate, even though its revision restarts lower.
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 12, epoch: "epoch-1", full: true)
    )
    let newEpochBaseline = try chainFrame(revision: 1, epoch: "epoch-2", full: true)

    #expect(MobileTerminalRenderGridRevisionContinuity.classify(newEpochBaseline, delivered: delivered) == .admit)
}

@Test func classifyAdmitsChainedDeltaAndMatchesAdmits() throws {
    let delivered = MobileTerminalRenderGridRevisionContinuity(
        delivered: try chainFrame(revision: 7, full: true)
    )
    let delta = try chainFrame(revision: 8, baseRevision: 7)

    #expect(MobileTerminalRenderGridRevisionContinuity.classify(delta, delivered: delivered) == .admit)
    #expect(MobileTerminalRenderGridRevisionContinuity.admits(delta, delivered: delivered))
}

@Test func classifyWithoutDeliveredRecordStaysChainBreak() throws {
    let delta = try chainFrame(revision: 9, baseRevision: 8)

    #expect(MobileTerminalRenderGridRevisionContinuity.classify(delta, delivered: nil) == .chainBreak)
}
