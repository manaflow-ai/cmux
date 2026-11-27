import CoreGraphics
import CmuxNextDesign
import Testing

/// Logins done right: a sign-in page opened from the onboarding tool window shows in the main window's pane
/// beside it, and the tool window slides sideways off that pane (`WindowPlacement.sideStep`). Leo: "theres no
/// reason for us not only to be able to have shit side by side opened where it's convienient". AppKit points.
@Suite struct SideStepPlacementTests {
    /// A 1440x875 visible frame and a 600x500 tool window.
    static let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    static func window(x: CGFloat) -> CGRect { CGRect(x: x, y: 200, width: 600, height: 500) }

    @Test func aWindowCoveringNoneOfThePaneStaysPut() {
        #expect(WindowPlacement.sideStep(Self.window(x: 0), clearing: CGRect(x: 600, y: 0, width: 840, height: 875), in: Self.visible) == nil)
        #expect(WindowPlacement.sideStep(Self.window(x: 0), clearing: CGRect(x: 0, y: 0, width: 1440, height: 150), in: Self.visible) == nil)
    }

    /// The pane is the right half; the window over its left edge slides left by 100, not right by 620.
    @Test func itClearsThePaneOnTheLeftWhenThatIsTheSmallerMove() {
        let pane = CGRect(x: 720, y: 0, width: 720, height: 875)
        #expect(WindowPlacement.sideStep(Self.window(x: 220), clearing: pane, in: Self.visible) == CGPoint(x: 120, y: 200))
    }

    /// The pane is the left part; the window over its right edge slides right.
    @Test func itClearsThePaneOnTheRightWhenThatIsTheSmallerMove() {
        let pane = CGRect(x: 0, y: 0, width: 700, height: 875)
        #expect(WindowPlacement.sideStep(Self.window(x: 500), clearing: pane, in: Self.visible) == CGPoint(x: 700, y: 200))
    }

    /// A pane wider than the room either side: the window goes to the screen edge leaving more of it uncovered.
    @Test func whenItCannotClearThePaneItTakesTheSideLeavingMoreUncovered() {
        let pane = CGRect(x: 200, y: 0, width: 1000, height: 875)
        // Left edge x 0 covers 400 of the pane; right edge x 840 covers 360.
        #expect(WindowPlacement.sideStep(Self.window(x: 420), clearing: pane, in: Self.visible) == CGPoint(x: 840, y: 200))
    }

    /// Clearing to the right would leave the screen, so the window clears on the left even though that moves it further.
    @Test func theMoveStaysInsideTheVisibleFrame() {
        let pane = CGRect(x: 700, y: 0, width: 400, height: 875)
        let placed = WindowPlacement.sideStep(Self.window(x: 800), clearing: pane, in: Self.visible)
        #expect(placed == CGPoint(x: 100, y: 200))
        let screen = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let onSecond = WindowPlacement.sideStep(CGRect(x: 1500, y: 200, width: 600, height: 500), clearing: CGRect(x: 1440, y: 0, width: 1000, height: 1055), in: screen)
        #expect(onSecond == CGPoint(x: 2440, y: 200))
    }
}
