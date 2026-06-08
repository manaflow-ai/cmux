import XCTest

@testable import CMUXMobileCore

/// Behavioral coverage for the phone's authoritative-grid pin decision.
///
/// The pin is the single source of truth for the mobile surface geometry: it
/// converges on initial attach and on any Mac-side resize from the ordered
/// render-grid frame stream. Live ordering is guaranteed by the `AsyncStream`
/// itself; the sequence here is the defensive backstop that stops a cold-attach
/// replay from applying an older grid over a newer live frame. These tests
/// exercise that contract directly, without UIKit, so the class of "stale
/// initial height / pin goes stale on resize" bugs is caught at the model
/// boundary.
final class MobileTerminalGeometryPinTests: XCTestCase {
    private func nextPin(
        current: MobileTerminalGridPin?,
        columns: Int,
        rows: Int,
        seq: UInt64
    ) -> MobileTerminalGridPin? {
        MobileTerminalGeometryPinDecision.nextPin(
            current: current,
            incomingColumns: columns,
            incomingRows: rows,
            incomingSeq: seq
        )
    }

    // MARK: - Initial attach

    func testFirstFrameSetsTheInitialPinUnconditionally() {
        let pin = nextPin(current: nil, columns: 80, rows: 40, seq: 7)
        XCTAssertEqual(pin, MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 7))
    }

    func testAttachYieldsCorrectSizeEvenAtSequenceZero() {
        // A cold-attach replay can carry seq 0 (no bytes flowed yet); it must
        // still establish the correct initial grid rather than render at a
        // guessed local size.
        let pin = nextPin(current: nil, columns: 100, rows: 30, seq: 0)
        XCTAssertEqual(pin, MobileTerminalGridPin(columns: 100, rows: 30, geometrySeq: 0))
    }

    // MARK: - Replay-vs-live overlap backstop (older frame cannot win)

    func testOlderReplayFrameDoesNotOverwriteNewerLiveGrid() {
        // A cold-attach replay overlaps the first live frames and lands late
        // carrying an older sequence + smaller grid; it must be ignored so the
        // newer live grid stands.
        let current = MobileTerminalGridPin(columns: 100, rows: 40, geometrySeq: 50)
        let stale = nextPin(current: current, columns: 60, rows: 24, seq: 49)
        XCTAssertNil(stale, "a strictly older frame must not move the pin")
    }

    func testOlderFrameDoesNotLowerGridEvenIfItReportsSmaller() {
        // The backstop in action: a delayed smaller frame at an older sequence
        // than the applied grid is dropped.
        let current = MobileTerminalGridPin(columns: 120, rows: 50, geometrySeq: 200)
        XCTAssertNil(nextPin(current: current, columns: 40, rows: 10, seq: 5))
    }

    // MARK: - Mac-side resize converges (Bug B)

    func testMacResizeLargerAdvancesThePin() {
        // Mac pane was the constraint; phone letterboxed at 50x30. The Mac
        // window grows, the next frame carries the larger grid at a newer
        // sequence, and the pin must follow with no phone-initiated report.
        let current = MobileTerminalGridPin(columns: 50, rows: 30, geometrySeq: 10)
        let grown = nextPin(current: current, columns: 80, rows: 40, seq: 11)
        XCTAssertEqual(grown, MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 11))
    }

    func testCoDeviceDetachGrowthConverges() {
        // A second device detaches, the shared min grows, and the remaining
        // phone's next frame carries the larger grid. Same stale-pin class as a
        // Mac resize, handled by the same decision.
        let current = MobileTerminalGridPin(columns: 50, rows: 20, geometrySeq: 100)
        let grown = nextPin(current: current, columns: 90, rows: 40, seq: 101)
        XCTAssertEqual(grown, MobileTerminalGridPin(columns: 90, rows: 40, geometrySeq: 101))
    }

    // MARK: - No-op cases

    func testUnchangedGridDoesNotChurnThePin() {
        let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 10)
        XCTAssertNil(
            nextPin(current: current, columns: 80, rows: 40, seq: 20),
            "same grid at a newer sequence should not re-pin"
        )
    }

    func testSameSequenceDifferentGridStillUpdates() {
        // A resize whose byte sequence did not advance still changes the grid;
        // the grid is the fact being tracked, so it must update.
        let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 10)
        let resized = nextPin(current: current, columns: 80, rows: 50, seq: 10)
        XCTAssertEqual(resized, MobileTerminalGridPin(columns: 80, rows: 50, geometrySeq: 10))
    }

    func testNonPositiveGridIsRejectedAndNeverClearsThePin() {
        let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 10)
        XCTAssertNil(nextPin(current: current, columns: 0, rows: 40, seq: 11))
        XCTAssertNil(nextPin(current: current, columns: 80, rows: 0, seq: 11))
        XCTAssertNil(nextPin(current: nil, columns: 0, rows: 0, seq: 1))
    }

    // MARK: - Monotonic high-water mark

    func testSequenceNeverRewindsWhenAGridChangeIsApplied() {
        // A newer-grid frame at the same sequence as the current high-water
        // mark keeps the mark, so a subsequent older frame is still rejected.
        let current = MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 30)
        let updated = nextPin(current: current, columns: 80, rows: 41, seq: 30)
        XCTAssertEqual(updated?.geometrySeq, 30)
        XCTAssertNil(nextPin(current: updated, columns: 60, rows: 20, seq: 29))
    }

    func testConvergenceUnderInterleavedOrdering() {
        // Replay a realistic interleaving: initial attach, a couple of
        // resizes, then a late stale frame, then steady-state. The pin must end
        // on the newest grid and never have been dragged backward.
        var pin = nextPin(current: nil, columns: 50, rows: 30, seq: 5)
        XCTAssertEqual(pin, MobileTerminalGridPin(columns: 50, rows: 30, geometrySeq: 5))

        pin = nextPin(current: pin, columns: 80, rows: 40, seq: 9) ?? pin
        XCTAssertEqual(pin, MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 9))

        // A delayed smaller frame from before the resize must be dropped.
        XCTAssertNil(nextPin(current: pin, columns: 50, rows: 30, seq: 6))

        // Steady-state same grid, newer seq: no churn.
        XCTAssertNil(nextPin(current: pin, columns: 80, rows: 40, seq: 12))

        XCTAssertEqual(pin, MobileTerminalGridPin(columns: 80, rows: 40, geometrySeq: 9))
    }
}
