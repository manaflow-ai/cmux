import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// Dragging a divider, judged on every 120 Hz frame the window server shows (Lawrence
/// 2026-11-01: "resizing columns and rows needs tests to ensure pixel perfect animations"; plan in
/// STATUS 2691): the panes' edges follow the pointer 1:1 in points, within 1 device pixel, one
/// display refresh at a time with no dropped frame, on the device-pixel grid, with no gap or
/// overlap, and the frame after the release is the final layout exactly. The path stays clear of
/// the soft snaps (8 pt around 1/3, 1/2, 2/3 and the equal share, plans/cmux-next/resize-modifiers.md),
/// so every frame is the pointer's. 1x and 2x, light and dark, and with every animation off.
///
/// A display step runs these (`cmux-ci run --display`, CMUX_TEST_REQUIRE_GUI=1); without a screen
/// there they fail, never skip.
@MainActor
@Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)),
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1" || NSScreen.main != nil,
                "animation pixel tests draw on a display: a display step runs them and fails without a screen"))
struct DividerDragPixelTests {
    /// Side by side: the divider moves along x (a row scanline reads it).
    static let sideBySide = ScreenLayout.splits(.split("x", axis: .horizontal, ratio: 0.55, a: .leaf("p1"), b: .leaf("p2")))
    /// Stacked: the divider moves along y (a column scanline reads it).
    static let stacked = ScreenLayout.splits(.split("y", axis: .vertical, ratio: 0.53, a: .leaf("p1"), b: .leaf("p2")))

    /// The boundaries on each side of the pressed band move with the pointer; the rest stay.
    static func bandEdges(_ boundary: Int, _ elements: [ScanlineElement]) -> Bool {
        elements[boundary].free || elements[boundary + 1].free
    }

    @Test(arguments: [1, 2], [false, true])
    func draggingASideBySideDividerFollowsThePointerOnThePixelGrid(scale: Int, dark: Bool) async throws {
        try await Self.drag(Self.sideBySide, kind: .split("x"), axis: .row, distance: 96, scale: scale, dark: dark, animations: true)
    }

    @Test(arguments: [1, 2], [false, true])
    func draggingAStackedDividerFollowsThePointerOnThePixelGrid(scale: Int, dark: Bool) async throws {
        try await Self.drag(Self.stacked, kind: .split("y"), axis: .column, distance: 80, scale: scale, dark: dark, animations: true)
    }

    @Test(arguments: [1, 2])
    func withAnimationsOffADividerDragStillFollowsThePointer(scale: Int) async throws {
        try await Self.drag(Self.sideBySide, kind: .split("x"), axis: .row, distance: 96, scale: scale, dark: false, animations: false)
    }

    /// Out `distance` points at 4 pt a refresh (480 pt/s) and back. In the 1200 x 700 pt window the
    /// side-by-side divider goes 659 -> 755 pt (snaps 400, 600, 800 +- 8) and the stacked one
    /// 370 -> 450 pt (snaps 233, 350, 466 +- 8).
    static func drag(_ layout: ScreenLayout, kind: DividerHandleView.Kind, axis: AnimationPixelRun.Axis, distance: Double, scale: Int,
                     dark: Bool, animations: Bool) async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("the own-process window capture needs macOS 14.4")
            return
        }
        let fixture = try await LayoutPixelFixture(layout: layout, focused: "p1", scale: scale, dark: dark, animations: animations)
        defer { fixture.close() }
        let run = AnimationPixelRun(fixture: fixture, name: "drag-\(kind.geometryLabel)-\(scale)x-\(dark ? "dark" : "light")\(animations ? "" : "-off")")
        let failures = try await run.judgeDrag(kind, axis: axis, path: PointerDriver.outAndBack(distance: distance, step: 4), moving: bandEdges)
        AnimationPixelHarnessTests.record(failures)
    }
}
