import Testing

@testable import CMUXMobileCore

/// Behavioral coverage for the phone's authoritative-grid pin decision.
///
/// The pin is the single source of truth for the mobile surface geometry: it
/// converges on initial attach and on any Mac-side resize from the ordered
/// render-grid frame stream, merged with the out-of-band viewport reply. Live
/// ordering is guaranteed by the `AsyncStream` itself; the geometry generation
/// is the order key that merges the reply safely and tells the surface whether
/// an incoming frame's bytes are stale. These tests exercise that contract
/// directly, without UIKit, so the class of "stale initial height / pin goes
/// stale on resize / stale bytes repaint" bugs is caught at the model boundary.
private func verdict(
    current: MobileTerminalGridPin?,
    columns: Int,
    rows: Int,
    seq: UInt64,
    source: MobileTerminalGeometryPinSource = .stream
) -> MobileTerminalGeometryPinVerdict {
    mobileTerminalGeometryPinVerdict(
        current: current,
        incomingColumns: columns,
        incomingRows: rows,
        incomingSeq: seq,
        source: source
    )
}

/// The pin a verdict applies, or `nil` for `.stale`/`.keep` (which leave the
/// pin untouched). Lets the convergence tests thread the pin forward.
private func appliedPin(
    _ verdict: MobileTerminalGeometryPinVerdict,
    current: MobileTerminalGridPin?
) -> MobileTerminalGridPin? {
    switch verdict {
    case .stale, .keep: return current
    case let .update(pin): return pin
    }
}

// MARK: - Initial attach

@Test func firstFrameUpdatesToTheInitialPinUnconditionally() {
    #expect(
        verdict(current: nil, columns: 80, rows: 40, seq: 7)
            == .update(MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 7))
    )
}

@Test func attachYieldsCorrectSizeEvenAtGenerationZero() {
    // A cold-attach replay can carry generation 0 (no resize observed yet); it
    // must still establish the correct initial grid rather than render at a
    // guessed local size.
    #expect(
        verdict(current: nil, columns: 100, rows: 30, seq: 0)
            == .update(MobileTerminalGridPin(columns: 100, rows: 30, geometrySeq: 0))
    )
}

@Test func firstFrameWithNonPositiveGridKeepsBytesButDoesNotPin() {
    // A degenerate first frame carries no usable geometry; its bytes are still
    // current (keep), but it must not establish a 0-sized pin.
    #expect(verdict(current: nil, columns: 0, rows: 0, seq: 1) == .keep)
}

// MARK: - Stale frames: drop the bytes

@Test func olderGenerationFrameIsStaleSoItsBytesAreDropped() {
    // A cold-attach replay overlaps the first live frames and lands late
    // carrying an older generation. The viewport reply can advance the pin
    // out-of-band, so even a byte-current replay can be geometry-stale; its
    // bytes would repaint stale content at the newer grid, so it is `.stale`.
    let current = MobileTerminalGridPin(columns: 100, rows: 40, geometrySeq: 50)
    #expect(verdict(current: current, columns: 60, rows: 24, seq: 49) == .stale)
}

@Test func olderGenerationStaleEvenWhenItReportsTheSameGrid() {
    // Same-grid but older generation is still stale (a delayed replay after the
    // pin already advanced): drop its bytes.
    let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 12)
    #expect(verdict(current: current, columns: 80, rows: 40, seq: 9) == .stale)
}

// MARK: - Mac-side resize converges (Bug B)

@Test func macResizeLargerAdvancesThePin() {
    // Mac pane was the constraint; phone letterboxed at 50x30. The Mac window
    // grows, the next frame carries the larger grid at a newer generation, and
    // the pin must follow with no phone-initiated report.
    let current = MobileTerminalGridPin(columns: 50, rows: 30, geometrySeq: 10)
    #expect(
        verdict(current: current, columns: 80, rows: 40, seq: 11)
            == .update(MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 11))
    )
}

@Test func coDeviceDetachGrowthConverges() {
    // A second device detaches, the shared min grows, and the remaining phone's
    // next frame carries the larger grid. Same stale-pin class as a Mac resize,
    // handled by the same decision.
    let current = MobileTerminalGridPin(columns: 50, rows: 20, geometrySeq: 100)
    #expect(
        verdict(current: current, columns: 90, rows: 40, seq: 101)
            == .update(MobileTerminalGridPin(columns: 90, rows: 40, geometrySeq: 101))
    )
}

// MARK: - Legacy equal-generation different grid (geometry_gen == 0 host)

@Test func legacyStreamEqualGenerationResizeApplies() {
    // On a legacy host every frame carries gen 0, so a real Mac-side resize is
    // an equal-generation different-grid stream frame. It MUST apply, otherwise
    // a Mac-side grow (Bug B) is never learned on legacy. Ordering comes from
    // the AsyncStream, not the generation.
    let current = MobileTerminalGridPin(columns: 50, rows: 30, geometrySeq: 0)
    #expect(
        verdict(current: current, columns: 80, rows: 40, seq: 0, source: .stream)
            == .update(MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 0))
    )
}

@Test func legacyViewportReplyEqualGenerationDifferentGridIsStale() {
    // The out-of-band viewport reply has no stream ordering, so an
    // equal-generation different-grid reply could rewind a same-generation
    // stream frame. Reject it as stale so it cannot overwrite the pin or apply
    // its (reply carries no) bytes.
    let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 0)
    #expect(verdict(current: current, columns: 50, rows: 30, seq: 0, source: .viewportReply) == .stale)
}

@Test func viewportReplyStrictlyNewerDifferentGridApplies() {
    // A viewport reply that IS strictly newer (a gen-stamping host, or after the
    // generation advanced) still converges the pin.
    let current = MobileTerminalGridPin(columns: 50, rows: 30, geometrySeq: 4)
    #expect(
        verdict(current: current, columns: 80, rows: 40, seq: 5, source: .viewportReply)
            == .update(MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 5))
    )
}

// MARK: - Keep cases (apply bytes, no pin change)

@Test func unchangedGridAtSameOrOlderGenerationKeepsBytes() {
    // Same grid, no newer generation: the bytes are current (keep) but nothing
    // about the pin changes. (An older generation with the SAME grid is `.stale`
    // — covered separately — only the equal generation is `.keep`.)
    let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 10)
    #expect(verdict(current: current, columns: 80, rows: 40, seq: 10) == .keep)
}

@Test func nonPositiveGridKeepsBytesAndNeverClearsThePin() {
    let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 10)
    #expect(verdict(current: current, columns: 0, rows: 40, seq: 11) == .keep)
    #expect(verdict(current: current, columns: 80, rows: 0, seq: 11) == .keep)
}

// MARK: - Monotonic high-water mark

@Test func unchangedGridAtNewerGenerationAdvancesTheHighWaterMark() {
    // The grid did not change, so no geometry apply is needed, but the stored
    // generation MUST advance: otherwise a later delayed frame at an
    // intermediate generation could pass the staleness check and overwrite the
    // pin. The update keeps the same grid (caller's apply is a no-op) and
    // carries the newer generation.
    let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 10)
    #expect(
        verdict(current: current, columns: 80, rows: 40, seq: 20)
            == .update(MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 20))
    )
}

@Test func delayedIntermediateFrameCannotWinAfterResizeAwayAndBack() {
    // Regression for the high-water-mark gap: pin 80x40@10, resize away to
    // 100x50@11, then back to 80x40@12. The back-to-current frame must advance
    // the stored generation to 12 so a delayed 100x50@11 is rejected as stale.
    var pin: MobileTerminalGridPin? = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 10)
    pin = appliedPin(verdict(current: pin, columns: 100, rows: 50, seq: 11), current: pin)
    #expect(pin == MobileTerminalGridPin(columns: 100, rows: 50, geometrySeq: 11))
    pin = appliedPin(verdict(current: pin, columns: 80, rows: 40, seq: 12), current: pin)
    #expect(pin == MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 12))
    // The delayed intermediate-grid frame at generation 11 must be stale.
    #expect(verdict(current: pin, columns: 100, rows: 50, seq: 11) == .stale)
}

@Test func convergenceUnderInterleavedOrdering() {
    // Replay a realistic interleaving: initial attach, a couple of resizes,
    // then a late stale frame, then steady-state. The pin must end on the
    // newest grid and never have been dragged backward.
    var pin: MobileTerminalGridPin?
    pin = appliedPin(verdict(current: pin, columns: 50, rows: 30, seq: 5), current: pin)
    #expect(pin == MobileTerminalGridPin(columns: 50, rows: 30, geometrySeq: 5))

    pin = appliedPin(verdict(current: pin, columns: 80, rows: 40, seq: 9), current: pin)
    #expect(pin == MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 9))

    // A delayed smaller frame from before the resize is stale.
    #expect(verdict(current: pin, columns: 50, rows: 30, seq: 6) == .stale)

    // Steady-state same grid, newer generation: keep the grid, advance the mark.
    pin = appliedPin(verdict(current: pin, columns: 80, rows: 40, seq: 12), current: pin)
    #expect(pin == MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 12))
}
