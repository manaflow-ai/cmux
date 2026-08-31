import Testing
@testable import CMUXMobileCore

private func chainFrame(
    revision: UInt64,
    epoch: String = "epoch-1",
    full: Bool = false,
    baseRevision: UInt64? = nil
) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: revision,
        renderEpoch: epoch,
        renderRevision: revision,
        columns: 8,
        rows: 2,
        full: full,
        clearedRows: full ? [] : [0],
        rowSpans: [.init(row: 0, column: 0, text: "row")],
        deltaBaseRenderRevision: baseRevision
    )
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

@Test func revisionContinuityAdmitsEpochlessDeltaWithBase() throws {
    // Epochless frames record no delivered identity, so rejecting their
    // deltas would request replays forever; the history chain governs them.
    let epochlessDelta = try chainFrame(revision: 8, epoch: "", baseRevision: 7)

    #expect(MobileTerminalRenderGridRevisionContinuity.admits(epochlessDelta, delivered: nil))
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
