import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// Core Animation runs the springs only in a real window on a real display: the on-screen bench (CMUX_PANE_BENCH=1),
/// as for `ScreenSwitchRenderMotionTests`.
nonisolated private let onScreenBench = ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"

/// A switch back while a screen switch runs on the render server (`motion.renderServer` on), in a window whose width
/// is not a multiple of 25 pt (1441 pt: the slide-out rests 259.38 pt away, off the device-pixel grid). Review of
/// #32609: the retarget put the outgoing screen at its raw rest, and `applyScreenFrames` (which places screens at the
/// rounded origin since the #31591 port) found it "moved" and stopped the first switch's position springs on it and on
/// its rings and dims: the screen jumped by the rest of its first slide. Now each screen rests on the grid in the
/// switch's turn, so the first switch's springs go on under the second one's, as at any other width.
@MainActor
@Suite(.serialized)
struct ScreenSwitchRenderPixelGridTests {
    typealias Harness = ScreenSwitchRenderMotionTests

    @Test(.enabled(if: onScreenBench)) func aSwitchBackMidFlightKeepsTheFirstSlideAtAWidthOffThePixelGrid() async throws {
        try await Harness.withMotion {
            let screens = Harness.Screens(renderServer: true)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            screens.window.setContentSize(NSSize(width: 1441, height: 800))
            screens.root.layoutSubtreeIfNeeded()
            let scale = screens.window.backingScaleFactor
            let slide = screens.shift * scale
            try #require(abs(slide - slide.rounded()) > 0.01, "the slide (\(screens.shift) pt) is on the grid at scale \(scale)")
            let clock = try #require(screens.root.layer)
            Harness.freeze(clock)

            screens.show("b")
            try #require(screens.root.screenSwitch.screens == ["a", "b"], "the switch is not on the render server")
            let half = Harness.time(toProgress: 0.5, Motion.panes.spring(.screen))
            let b = try screens.layer("b")
            let firstSprings = Set((b.animationKeys() ?? []).filter { $0.hasPrefix("cmux.renderSpring.") && $0.contains(".position") })
            try #require(!firstSprings.isEmpty, "b does not slide in on the render server")
            // The switch back lands at `half` on the frozen clock: its springs begin there.
            let before = try Harness.presented(b, at: half, root: clock)

            screens.show("a")
            let kept = Set(b.animationKeys() ?? [])
            #expect(firstSprings.isSubset(of: kept), "the switch back stopped b's first slide: \(firstSprings.subtracting(kept))")
            let after = try Harness.presented(b, at: half, root: clock)
            #expect(abs(after.x - before.x) < 1 / scale, "b jumped from x \(before.x) to \(after.x) when the switch turned back")
            let origin = try screens.view("b").frame.origin
            #expect(abs(origin.x * scale - (origin.x * scale).rounded()) <= 0.001, "b rests off the device grid at \(origin.x)")
        }
    }
}
