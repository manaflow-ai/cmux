import CoreGraphics
import XCTest
@testable import CmuxMobileTerminal

/// Leo, 2026-11-23: a full-screen app's scroll is jagged next to a shell's. The screen reads how
/// far the app moved its rows from the presented frames, and glides the band there.
final class TerminalTUIRowMoveTests: XCTestCase {
    /// A Claude Code-like screen: header row 0, transcript rows 1..<25 showing transcript lines
    /// from `first`, a spinner row 25 and an input box 26..<29.
    private func screen(first: Int, spinner: UInt64 = 7) -> [UInt64] {
        var rows: [UInt64] = [1_000_000]
        rows += (0..<24).map { UInt64(10 + first + $0) }
        rows.append(2_000_000 + spinner)
        rows += [3_000_000, 3_000_001, 3_000_002]
        return rows
    }

    func testOlderRowsComingInAtTheTopMoveTheTranscriptDown() {
        let move = TerminalTUIRowMove.between(previous: screen(first: 100), current: screen(first: 97, spinner: 8), rows: 0..<29)
        XCTAssertEqual(move, TerminalTUIRowMove(rows: 3, band: 1..<25))
    }

    func testNewerRowsComingInAtTheBottomMoveTheTranscriptUp() {
        let move = TerminalTUIRowMove.between(previous: screen(first: 100), current: screen(first: 103), rows: 0..<29)
        XCTAssertEqual(move, TerminalTUIRowMove(rows: -3, band: 1..<25))
    }

    func testARedrawInPlaceIsNoMove() {
        XCTAssertNil(TerminalTUIRowMove.between(previous: screen(first: 100), current: screen(first: 100, spinner: 9), rows: 0..<29))
    }

    func testANewScreenIsNoMove() {
        let other = (0..<29).map { UInt64(50_000 + $0) }
        XCTAssertNil(TerminalTUIRowMove.between(previous: screen(first: 100), current: other, rows: 0..<29))
    }

    func testBlankRowsLiningUpAreNoMove() {
        // A mostly blank screen whose only text row changed: blank rows match at every shift,
        // but none of them changed, so nothing moved.
        var before = [UInt64](repeating: 0, count: 29), after = before
        before[3] = 5
        after[10] = 6
        XCTAssertNil(TerminalTUIRowMove.between(previous: before, current: after, rows: 0..<29))
    }

    func testTheGlideStartsWhereTheLastFrameWasAndArrivesBeforeTheNextJump() {
        var glide = TerminalTUIRowGlide()
        glide.jumped(rows: 3, rowHeight: 17, at: 1.0)
        XCTAssertEqual(glide.offset, -51)
        var t = 0.0
        var steps: [CGFloat] = []
        var last = glide.offset
        while glide.step(dt: 1.0 / 120) {
            t += 1.0 / 120
            steps.append(abs(glide.offset - last))
            last = glide.offset
        }
        XCTAssertEqual(glide.offset, 0)
        XCTAssertLessThanOrEqual(t, TerminalTUIRowGlide.startInterval)
        // Steady: every frame moves about the same, well under a row.
        XCTAssertLessThan(steps.max() ?? 99, 17)
    }

    func testTheGlideLearnsTheAppsCadence() {
        var glide = TerminalTUIRowGlide()
        for jump in 0..<8 { glide.jumped(rows: 3, rowHeight: 17, at: Double(jump) * 0.1) }
        XCTAssertEqual(glide.interval, 0.1, accuracy: 0.002)
        // A pause starts a new burst: it is not the cadence.
        glide.jumped(rows: 3, rowHeight: 17, at: 5)
        XCTAssertEqual(glide.interval, 0.1, accuracy: 0.002)
    }

    func testSmoothnessOfJumpsAndOfAGlide() {
        // Three rows every six frames: still most of the time, a jump of three rows.
        let jumps = (0..<60).map { CGFloat(($0 / 6) * 51) }
        let jagged = TerminalScrollSmoothness(positions: jumps)
        XCTAssertEqual(jagged?.stepMax, 51)
        XCTAssertGreaterThan(jagged?.stillShare ?? 0, 0.7)
        // The same distance a little every frame.
        let glide = (0..<60).map { CGFloat($0) * 51 / 6 }
        let smooth = TerminalScrollSmoothness(positions: glide)
        XCTAssertEqual(smooth?.stillShare, 0)
        XCTAssertEqual(Double(smooth?.stepP95 ?? 0), 8.5, accuracy: 0.01)
        XCTAssertEqual(smooth?.note(rowHeight: 17), " motionFrames=59 stepP50Pct=50 stepP95Pct=50 stepMaxPct=50 stillPct=0")
        XCTAssertNil(TerminalScrollSmoothness(positions: [3, 3, 3]))
    }
}
