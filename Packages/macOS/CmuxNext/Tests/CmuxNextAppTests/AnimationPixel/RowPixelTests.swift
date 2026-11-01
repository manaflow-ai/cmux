import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// Closing a row, judged on every 120 Hz frame the window server shows along a vertical scanline
/// (Lawrence 2026-11-01: "resizing columns and rows"; plan in STATUS 2691). The layout model gets
/// the layout the daemon would send. Two rows of 500 permille fit the 700 pt window; closing the
/// lower one leaves the column one row, which springs into the space on the close spring
/// (`split`, close-animation/DESIGN.md), as a column close does on the other axis. Every frame
/// shows the row edge's idle line at its exact width, on the grid. 1x and 2x,
/// light and dark, and with every animation off.
///
/// New Row is not here yet: by default (`layout.newRowHeight` matchCurrent, rows.md G3) a new row
/// is as tall as the focused one, so the column overflows and its row camera scrolls to reveal it
/// (V3); that oracle needs the row camera and comes in its own change.
@MainActor
@Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)),
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1" || NSScreen.main != nil,
                "animation pixel tests draw on a display: a display step runs them and fails without a screen"))
struct RowPixelTests {
    static let one = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1"))])
    static let two = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.5,
                                                        root: .split("rr", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                                        rows: [LayoutRow(id: "r1", height: 500, root: .leaf("p1")),
                                                               LayoutRow(id: "r2", height: 500, root: .leaf("p2"))])])

    /// Three rows to two: the column keeps rows on both sides of the change.
    static let three = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.5,
                                                          root: .split("rr", axis: .vertical, ratio: 0.333, a: .leaf("p1"),
                                                                       b: .split("rs", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))),
                                                          rows: [LayoutRow(id: "r1", height: 333, root: .leaf("p1")),
                                                                 LayoutRow(id: "r2", height: 333, root: .leaf("p2")),
                                                                 LayoutRow(id: "r3", height: 334, root: .leaf("p3"))])])
    static let twoOfThree = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.5,
                                                               root: .split("rr", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                                               rows: [LayoutRow(id: "r1", height: 333, root: .leaf("p1")),
                                                                      LayoutRow(id: "r2", height: 333, root: .leaf("p2"))])])

    /// Closing the last of three rows: the rows left keep their heights in permille, so on screen
    /// nothing should move but the closed row going; if anything moves, it moves on the close spring.
    @Test(arguments: [1, 2])
    func closingOneOfThreeRowsJudgedFrameByFrame(scale: Int) async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("the own-process window capture needs macOS 14.4")
            return
        }
        let fixture = try await LayoutPixelFixture(layout: three, focused: "p1", scale: scale, dark: false, animations: true)
        defer { fixture.close() }
        fixture.model.rowsEnabledOverride = true
        fixture.root.syncWithModel()
        try await fixture.settle()
        let run = AnimationPixelRun(fixture: fixture, name: "close-row-3to2-\(scale)x")
        let period = fixture.display.refreshPeriod
        let declared = try DeclaredSpring.declared(.split)
        let failures = try await run.judge(.column, moves: false, oracle: { ScanlineOracle.spring(declared, $0, period: period) }) {
            fixture.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: twoOfThree)])
            fixture.root.syncWithModel()
        }
        AnimationPixelHarnessTests.record(failures)
    }

    @Test(arguments: [1, 2], [false, true])
    func closingARowSpringsTheRowLeftIntoItsSpace(scale: Int, dark: Bool) async throws {
        try await Self.close(scale: scale, dark: dark, animations: true)
    }

    @Test(arguments: [1, 2])
    func withAnimationsOffClosingARowLandsInOneFrame(scale: Int) async throws {
        try await Self.close(scale: scale, dark: false, animations: false)
    }

    static func close(scale: Int, dark: Bool, animations: Bool) async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("the own-process window capture needs macOS 14.4")
            return
        }
        let fixture = try await LayoutPixelFixture(layout: two, focused: "p1", scale: scale, dark: dark, animations: animations)
        defer { fixture.close() }
        fixture.model.rowsEnabledOverride = true
        fixture.root.syncWithModel()
        try await fixture.settle()
        let run = AnimationPixelRun(fixture: fixture, name: "close-row-\(scale)x-\(dark ? "dark" : "light")\(animations ? "" : "-off")")
        let failures = try await run.judgeSpring(.column, spring: .split, animated: animations) {
            fixture.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: one)])
        }
        AnimationPixelHarnessTests.record(failures)
    }
}
