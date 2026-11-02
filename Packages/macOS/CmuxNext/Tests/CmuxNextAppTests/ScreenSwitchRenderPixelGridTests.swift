import AppKit
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// Core Animation runs the springs only in a real window on a real display: the on-screen bench (CMUX_PANE_BENCH=1),
/// as for `ScreenSwitchRenderMotionTests`.
nonisolated private let onScreenBench = ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"

/// A screen switch on the render server (`motion.renderServer` on) puts each screen at its rest on the device-pixel
/// grid, the origin the CPU placement (`applyScreenFrames`) gives it. A slide-out rests 18 % of the width away: in a
/// window whose width is not a multiple of 25 pt that is off the grid (1441 pt: 259.38 pt). Review of #32609: the
/// switch put the view at the raw rest while `applyScreenFrames` compares it with the rounded one, so the next
/// placement in flight (a second switch, a layout pass) found the screen "moved" and stopped its position springs and
/// its rings' and dims': the screen jumped by the rest of its slide.
@MainActor
@Suite(.serialized)
struct ScreenSwitchRenderPixelGridTests {
    typealias Harness = ScreenSwitchRenderMotionTests

    static func onGrid(_ value: CGFloat, scale: CGFloat) -> Bool {
        abs(value * scale - (value * scale).rounded()) <= 0.001
    }

    @Test(.enabled(if: onScreenBench)) func aSwitchRestsOnThePixelGridAndAPlacementInFlightKeepsItsSlide() async throws {
        try await Harness.withMotion {
            let screens = Harness.Screens(renderServer: true)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            screens.window.setContentSize(NSSize(width: 1441, height: 800))
            screens.root.layoutSubtreeIfNeeded()
            let scale = screens.window.backingScaleFactor
            try #require(!Self.onGrid(screens.shift, scale: scale), "the slide (\(screens.shift) pt) is on the grid at scale \(scale)")

            screens.show("b")
            let root = screens.root
            try #require(root.screenSwitch.screens == ["a", "b"], "the switch is not on the render server: \(root.screenSwitch.screens)")
            for id: ScreenID in ["a", "b"] {
                let origin = try screens.view(id).frame.origin
                #expect(Self.onGrid(origin.x, scale: scale) && Self.onGrid(origin.y, scale: scale),
                        "\(id) rests off the device grid at \(origin) (scale \(scale))")
            }
            try #require(try Harness.hasPositionSprings(screens.layer("a")), "a does not slide out")
            let ringSlides = try Harness.hasPositionSprings(screens.chromeLayer("a"))

            // A placement of the screens in flight (a second switch's turn, a layout pass both run it).
            root.applyScreenFrames()
            #expect(try Harness.hasPositionSprings(screens.layer("a")), "a placement in flight stopped a's slide (it jumps to its rest)")
            if ringSlides {
                #expect(try Harness.hasPositionSprings(screens.chromeLayer("a")), "a placement in flight stopped a's ring's slide")
            }
            #expect(root.screenSwitch.isInFlight, "the placement ended the switch")
            #expect(await screens.landed(), "the switch did not land in 5 s")
            try screens.expectLanded(showing: "b", "a switch in a 1441 pt window")
        }
    }
}
