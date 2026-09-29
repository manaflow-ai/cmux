import CoreGraphics
@testable import CmuxNextApp
import Testing

/// Agent screenshot launches: `CMUX_NEXT_TEST_WINDOW_SCREEN` / `_FRAME`
/// place windows on a chosen screen, only with `CMUX_NEXT_NO_ACTIVATE=1`.
struct TestWindowPlacementTests {
    /// Main 1512x982 laptop (menu bar, dock) left of a 2560x1440 display.
    let screens = [
        CGRect(x: 0, y: 70, width: 1512, height: 875),
        CGRect(x: 1512, y: 0, width: 2560, height: 1415),
    ]

    @Test func requiresNoActivate() {
        let env = ["CMUX_NEXT_TEST_WINDOW_SCREEN": "last"]
        #expect(TestWindowPlacement.parse(env, noActivate: false) == nil)
        #expect(TestWindowPlacement.parse(env, noActivate: true)?.screen == .last)
        #expect(TestWindowPlacement.parse([:], noActivate: true) == nil)
    }

    @Test func parsesIndexAndRejectsGarbage() {
        #expect(TestWindowPlacement.parse(["CMUX_NEXT_TEST_WINDOW_SCREEN": "1"], noActivate: true)?.screen == .index(1))
        #expect(TestWindowPlacement.parse(["CMUX_NEXT_TEST_WINDOW_SCREEN": "-1"], noActivate: true) == nil)
        #expect(TestWindowPlacement.parse(["CMUX_NEXT_TEST_WINDOW_SCREEN": "second"], noActivate: true) == nil)
        #expect(TestWindowPlacement.parseFrame("10,20,800,600") == CGRect(x: 10, y: 20, width: 800, height: 600))
        #expect(TestWindowPlacement.parseFrame("10,20,0,600") == nil)
        #expect(TestWindowPlacement.parseFrame("10,20,800") == nil)
    }

    @Test func frameAloneUsesMainScreen() {
        let placement = TestWindowPlacement.parse(["CMUX_NEXT_TEST_WINDOW_FRAME": "0,0,800,600"], noActivate: true)
        #expect(placement == TestWindowPlacement(screen: .index(0), frame: CGRect(x: 0, y: 0, width: 800, height: 600)))
        // Top-left of the main visible frame, converted to AppKit's bottom-left origin.
        #expect(placement?.windowFrame(ordinal: 0, visibleFrames: screens) == CGRect(x: 0, y: 345, width: 800, height: 600))
    }

    @Test func lastScreenCentersDefaultSize() {
        let placement = TestWindowPlacement(screen: .last, frame: nil)
        #expect(placement.windowFrame(ordinal: 0, visibleFrames: screens) == CGRect(x: 1512 + 730, y: 347.5, width: 1100, height: 720))
        // One screen: last is the only screen.
        #expect(placement.windowFrame(ordinal: 0, visibleFrames: [screens[0]])?.minX == 206)
    }

    @Test func indexPastEndMeansLastAndFrameIsClamped() {
        let placement = TestWindowPlacement(screen: .index(7), frame: CGRect(x: 2000, y: 40, width: 4000, height: 600))
        let frame = placement.windowFrame(ordinal: 0, visibleFrames: screens)
        #expect(frame == CGRect(x: 1512, y: 1415 - 40 - 600, width: 2560, height: 600))
    }

    @Test func laterWindowsCascade() {
        let placement = TestWindowPlacement(screen: .index(1), frame: CGRect(x: 40, y: 40, width: 800, height: 600))
        let first = placement.windowFrame(ordinal: 0, visibleFrames: screens)
        let second = placement.windowFrame(ordinal: 1, visibleFrames: screens)
        #expect(second?.minX == (first?.minX ?? 0) + TestWindowPlacement.cascadeStep)
        #expect(second?.maxY == (first?.maxY ?? 0) - TestWindowPlacement.cascadeStep)
    }

    @Test func noScreensNoFrame() {
        #expect(TestWindowPlacement(screen: .last, frame: nil).windowFrame(ordinal: 0, visibleFrames: []) == nil)
    }
}
