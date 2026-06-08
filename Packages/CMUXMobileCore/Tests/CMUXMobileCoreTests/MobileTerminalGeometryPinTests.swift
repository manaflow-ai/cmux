import Testing

@testable import CMUXMobileCore

/// Behavioral coverage for the phone's authoritative-grid pin decision.
///
/// The pin is the single source of truth for the mobile surface geometry: it
/// converges on initial attach and on any Mac-side resize from the ordered
/// render-grid frame stream. Live ordering is guaranteed by the `AsyncStream`
/// itself; the geometry generation here is the order key that lets the
/// out-of-band viewport reply merge safely and stops a cold-attach replay from
/// applying an older grid over a newer live frame. These tests exercise that
/// contract directly, without UIKit, so the class of "stale initial height /
/// pin goes stale on resize" bugs is caught at the model boundary.
private func nextPin(
    current: MobileTerminalGridPin?,
    columns: Int,
    rows: Int,
    seq: UInt64
) -> MobileTerminalGridPin? {
    mobileTerminalNextGridPin(
        current: current,
        incomingColumns: columns,
        incomingRows: rows,
        incomingSeq: seq
    )
}

// MARK: - Initial attach

@Test func firstFrameSetsTheInitialPinUnconditionally() {
    let pin = nextPin(current: nil, columns: 80, rows: 40, seq: 7)
    #expect(pin == MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 7))
}

@Test func attachYieldsCorrectSizeEvenAtGenerationZero() {
    // A cold-attach replay can carry generation 0 (no resize observed yet); it
    // must still establish the correct initial grid rather than render at a
    // guessed local size.
    let pin = nextPin(current: nil, columns: 100, rows: 30, seq: 0)
    #expect(pin == MobileTerminalGridPin(columns: 100, rows: 30, geometrySeq: 0))
}

// MARK: - Replay-vs-live overlap backstop (older frame cannot win)

@Test func olderReplayFrameDoesNotOverwriteNewerLiveGrid() {
    // A cold-attach replay overlaps the first live frames and lands late
    // carrying an older generation + smaller grid; it must be ignored so the
    // newer live grid stands.
    let current = MobileTerminalGridPin(columns: 100, rows: 40, geometrySeq: 50)
    #expect(nextPin(current: current, columns: 60, rows: 24, seq: 49) == nil)
}

@Test func olderFrameDoesNotLowerGridEvenIfItReportsSmaller() {
    // The backstop in action: a delayed smaller frame at an older generation
    // than the applied grid is dropped.
    let current = MobileTerminalGridPin(columns: 120, rows: 50, geometrySeq: 200)
    #expect(nextPin(current: current, columns: 40, rows: 10, seq: 5) == nil)
}

// MARK: - Mac-side resize converges (Bug B)

@Test func macResizeLargerAdvancesThePin() {
    // Mac pane was the constraint; phone letterboxed at 50x30. The Mac window
    // grows, the next frame carries the larger grid at a newer generation, and
    // the pin must follow with no phone-initiated report.
    let current = MobileTerminalGridPin(columns: 50, rows: 30, geometrySeq: 10)
    let grown = nextPin(current: current, columns: 80, rows: 40, seq: 11)
    #expect(grown == MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 11))
}

@Test func coDeviceDetachGrowthConverges() {
    // A second device detaches, the shared min grows, and the remaining phone's
    // next frame carries the larger grid. Same stale-pin class as a Mac resize,
    // handled by the same decision.
    let current = MobileTerminalGridPin(columns: 50, rows: 20, geometrySeq: 100)
    let grown = nextPin(current: current, columns: 90, rows: 40, seq: 101)
    #expect(grown == MobileTerminalGridPin(columns: 90, rows: 40, geometrySeq: 101))
}

// MARK: - No-op cases

@Test func unchangedGridDoesNotChurnThePin() {
    let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 10)
    #expect(nextPin(current: current, columns: 80, rows: 40, seq: 20) == nil)
}

@Test func sameGenerationDifferentGridStillUpdates() {
    // A reply/frame whose generation did not advance can still change the grid;
    // the grid is the fact being tracked, so it must update.
    let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 10)
    let resized = nextPin(current: current, columns: 80, rows: 50, seq: 10)
    #expect(resized == MobileTerminalGridPin(columns: 80, rows: 50, geometrySeq: 10))
}

@Test func nonPositiveGridIsRejectedAndNeverClearsThePin() {
    let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 10)
    #expect(nextPin(current: current, columns: 0, rows: 40, seq: 11) == nil)
    #expect(nextPin(current: current, columns: 80, rows: 0, seq: 11) == nil)
    #expect(nextPin(current: nil, columns: 0, rows: 0, seq: 1) == nil)
}

// MARK: - Monotonic high-water mark

@Test func generationNeverRewindsWhenAGridChangeIsApplied() {
    // A newer-grid frame at the same generation as the current high-water mark
    // keeps the mark, so a subsequent older frame is still rejected.
    let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 30)
    let updated = nextPin(current: current, columns: 80, rows: 41, seq: 30)
    #expect(updated?.geometrySeq == 30)
    #expect(nextPin(current: updated, columns: 60, rows: 20, seq: 29) == nil)
}

@Test func convergenceUnderInterleavedOrdering() {
    // Replay a realistic interleaving: initial attach, a couple of resizes,
    // then a late stale frame, then steady-state. The pin must end on the
    // newest grid and never have been dragged backward.
    var pin = nextPin(current: nil, columns: 50, rows: 30, seq: 5)
    #expect(pin == MobileTerminalGridPin(columns: 50, rows: 30, geometrySeq: 5))

    pin = nextPin(current: pin, columns: 80, rows: 40, seq: 9) ?? pin
    #expect(pin == MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 9))

    // A delayed smaller frame from before the resize must be dropped.
    #expect(nextPin(current: pin, columns: 50, rows: 30, seq: 6) == nil)

    // Steady-state same grid, newer generation: no churn.
    #expect(nextPin(current: pin, columns: 80, rows: 40, seq: 12) == nil)

    #expect(pin == MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 9))
}
