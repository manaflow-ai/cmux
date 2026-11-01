import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// New Column and closing a column in the strip, judged on every 120 Hz frame the window server
/// shows (plan in STATUS 2691). The layout model gets the layout the daemon would send.
///
/// - New Column (R3b, Lawrence 2026-10-31: "creating new columns must never resize existing
///   columns"): an instant create (plans/cmux-next/PATTERNS.md P4), so every frame shows the
///   layout before or after it, never one between, and every column that was there keeps its
///   width in points in the model and in every drawn frame.
/// - Closing a column: its neighbours spring into its space on the close spring, the split's
///   (plans/cmux-next/close-animation/DESIGN.md: "a close is a split run backwards").
///
/// Both fit the window, so the strip camera stays. 1x and 2x, light and dark, animations off too.
@MainActor
@Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)),
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1" || NSScreen.main != nil,
                "animation pixel tests draw on a display: a display step runs them and fails without a screen"))
struct ColumnPixelTests {
    static let two = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.3, root: .leaf("p1")),
                                           LayoutColumn(id: "c2", width: 0.3, root: .leaf("p2"))])
    /// `two` with a new column right of the first, the place New Column puts it beside a focused p1.
    static let three = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.3, root: .leaf("p1")),
                                             LayoutColumn(id: "c3", width: 0.3, root: .leaf("p3")),
                                             LayoutColumn(id: "c2", width: 0.3, root: .leaf("p2"))])

    @Test(arguments: [1, 2], [false, true])
    func aNewColumnLandsInOneFrameAndKeepsEveryOldWidth(scale: Int, dark: Bool) async throws {
        try await Self.newColumn(scale: scale, dark: dark, animations: true)
    }

    @Test(arguments: [1, 2])
    func withAnimationsOffANewColumnLandsInOneFrame(scale: Int) async throws {
        try await Self.newColumn(scale: scale, dark: false, animations: false)
    }

    @Test(arguments: [1, 2], [false, true])
    func closingAColumnSpringsItsNeighbourIntoItsSpace(scale: Int, dark: Bool) async throws {
        try await Self.close(scale: scale, dark: dark, animations: true)
    }

    @Test(arguments: [1, 2])
    func withAnimationsOffClosingAColumnLandsInOneFrame(scale: Int) async throws {
        try await Self.close(scale: scale, dark: false, animations: false)
    }

    static func newColumn(scale: Int, dark: Bool, animations: Bool) async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("the own-process window capture needs macOS 14.4")
            return
        }
        let fixture = try await LayoutPixelFixture(layout: two, focused: "p1", scale: scale, dark: dark, animations: animations)
        defer { fixture.close() }
        let widths = try #require(fixture.screen).geometry.panes.mapValues(\.width)
        let run = AnimationPixelRun(fixture: fixture, name: "new-column-\(scale)x-\(dark ? "dark" : "light")\(animations ? "" : "-off")")
        let period = fixture.display.refreshPeriod
        var moved = false
        let failures = try await run.judge(.row, moves: false, oracle: { .spring(try DeclaredSpring.declared(.split), $0, period: period) }) {
            fixture.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: three)])
            fixture.root.syncWithModel()
            moved = fixture.screen?.hasMotion ?? false
        }
        AnimationPixelHarnessTests.record(failures)
        #expect(!moved, "a New Column started motion: an instant create shows its layout in one frame")
        let after = try #require(fixture.screen).geometry.panes
        for (pane, width) in widths {
            #expect(after[pane]?.width == width, "R3b: \(pane.rawValue) was \(width) pt wide, now \(String(describing: after[pane]?.width)) pt")
        }
    }

    static func close(scale: Int, dark: Bool, animations: Bool) async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("the own-process window capture needs macOS 14.4")
            return
        }
        let fixture = try await LayoutPixelFixture(layout: three, focused: "p1", scale: scale, dark: dark, animations: animations)
        defer { fixture.close() }
        let run = AnimationPixelRun(fixture: fixture, name: "close-column-\(scale)x-\(dark ? "dark" : "light")\(animations ? "" : "-off")")
        let failures = try await run.judgeSpring(.row, spring: .split, animated: animations) {
            fixture.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: two)])
        }
        AnimationPixelHarnessTests.record(failures)
    }
}
