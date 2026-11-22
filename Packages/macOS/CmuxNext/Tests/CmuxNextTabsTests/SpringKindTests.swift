import CoreGraphics
import Testing
@testable import CmuxNextTabs

/// A spring toward 0 used the `disappear` tuning whatever it animated, so a
/// tab sliding to x = 0 or the strip scrolling back to 0 moved with the
/// close tuning. The shared rule (cmux-motion SpringKind): size springs
/// keep it, position springs always use their own token.
@MainActor @Suite struct SpringKindTests {
    @Test func aTabMovingToXZeroKeepsThePositionTuning() {
        var x = TabMotion(x: 120, width: 80, alpha: 1).x
        x.target = 0
        #expect(x.activeToken == .move)
    }

    @Test func theStripScrollingBackToZeroKeepsTheScrollTuning() {
        var scroll = TabStripView(model: TabStripModel(tabs: [], selectedID: nil)).scroll
        scroll.value = 300
        scroll.target = 0
        #expect(scroll.activeToken == .scroll)
    }

    @Test func aSizeShrinkingToZeroStillDisappears() {
        var width = TabMotion(x: 0, width: 80, alpha: 1).width
        width.target = 0
        #expect(width.activeToken == .disappear)
        var alpha = TabMotion(x: 0, width: 80, alpha: 1).alpha
        alpha.target = 0
        #expect(alpha.activeToken == .disappear)
    }
}
