import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// What leaves ends sooner than what arrives, on real panes: a pane close ends visibly in fewer frames than the
/// split that it undoes, and an unzoom in fewer frames than its zoom.
///
/// The end of a motion is its visible end, by the rule of the token table (`MotionCapTests`,
/// `SpringParameters.perceivedDuration`): the last frame at which the pane is more than 0.5% of its travel from
/// its target. The test is the clock: frames step at a fixed 120 Hz dt (the rigs of `PaneCloseMotionTests` and
/// `PaneZoomMotionTests`), so each number is a frame count and not wall time. One frame is the resolution of a
/// count, so "sooner" here is sooner by more than one frame.
@MainActor
@Suite(.closesItsWindows)
struct PaneExitEndsSoonerTests {
    /// One second at 120 Hz: longer than a pane motion at any speed.
    static let frames = 120

    /// The frame at which a motion ends visibly: the last of `values` (one for each frame, the first is frame 1)
    /// that is more than 0.5% of the travel from `target`. 0 when no frame is.
    static func visibleEnd(_ values: [CGFloat], from start: CGFloat, to target: CGFloat) -> Int {
        (values.lastIndex { abs(target - $0) > abs(target - start) * 0.005 } ?? -1) + 1
    }

    @Test func aCloseEndsVisiblyInFewerFramesThanTheSplitItUndoes() throws {
        let screen = PaneCloseMotionTests.Screen(.splits(.leaf("p1")))
        defer { screen.tearDown() }
        // The width that p1 shows after each of one second's frames.
        func widths() throws -> [CGFloat] {
            try (1...Self.frames).map { _ in
                screen.step()
                return try #require(screen.screen?.displayedFrame(of: "p1")).width
            }
        }
        let whole = try #require(screen.screen?.displayedFrame(of: "p1")).width
        screen.show(.split("v", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))
        let half = try #require(screen.target("p1")).width
        try #require(half < whole * 0.6, "SETUP: the split gave p1 no new width (\(half) of \(whole))")
        let split = try Self.visibleEnd(widths(), from: whole, to: half)
        _ = try #require(screen.close("p2"), "SETUP: the pane did not close in the key's turn")
        let back = try #require(screen.target("p1")).width
        try #require(back > half * 1.6, "SETUP: the close gave p1 no new width (\(back) from \(half))")
        let close = try Self.visibleEnd(widths(), from: half, to: back)
        try #require(split > 2 && split < Self.frames, "SETUP: the split did not spring to rest: its visible end is frame \(split)")
        #expect(close > 0 && close < Self.frames, "the close did not spring to rest: its visible end is frame \(close)")
        #expect(close + 1 < split,
                "a close ends visibly at frame \(close) and the split that it undoes at frame \(split) (120 Hz): the close is not the sooner one")
    }

    @Test func anUnzoomEndsVisiblyInFewerFramesThanItsZoom() throws {
        let screen = PaneZoomMotionTests.Screen(PaneZoomMotionTests.grid2)
        defer { screen.window.closeAfterTest() }
        // The width that p4 shows after each of one second's frames.
        func widths() throws -> [CGFloat] {
            try (1...Self.frames).map { _ in
                screen.step()
                return try #require(screen.shown("p4")).width
            }
        }
        let slot = try #require(screen.shown("p4")).width
        screen.zoom("p4")
        let full = try #require(screen.screen?.geometry.panes["p4"]).width
        try #require(full > slot * 1.6, "SETUP: the zoom gave p4 no new width (\(full) from \(slot))")
        let zoom = try Self.visibleEnd(widths(), from: slot, to: full)
        screen.unzoom()
        let unzoom = try Self.visibleEnd(widths(), from: full, to: slot)
        try #require(zoom > 2 && zoom < Self.frames, "SETUP: the zoom did not spring to rest: its visible end is frame \(zoom)")
        #expect(unzoom > 0 && unzoom < Self.frames, "the unzoom did not spring to rest: its visible end is frame \(unzoom)")
        #expect(unzoom + 1 < zoom,
                "an unzoom ends visibly at frame \(unzoom) and its zoom at frame \(zoom) (120 Hz): the unzoom is not the sooner one")
    }
}
