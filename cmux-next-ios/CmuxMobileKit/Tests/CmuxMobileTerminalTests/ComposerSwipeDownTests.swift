#if os(iOS)
import CmuxMobileDesign
import CoreGraphics
import Testing

/// Leo, 2026-11-22 ~17:02Z: "chatgpt you csn swipe down inside the composer to collapse it. we need that here too."
@Suite struct ComposerSwipeDownTests {
    @Test func aDeliberateDownwardDragCollapses() {
        #expect(ComposerSwipeDown.collapses(dx: 0, dy: 30, velocityY: 0, ended: false))
        #expect(ComposerSwipeDown.collapses(dx: 10, dy: 40, velocityY: 0, ended: false))
    }

    @Test func aShortDragDoesNotCollapseUntilItIsAFlick() {
        #expect(!ComposerSwipeDown.collapses(dx: 0, dy: 12, velocityY: 200, ended: false))
        #expect(!ComposerSwipeDown.collapses(dx: 0, dy: 12, velocityY: 200, ended: true))
        #expect(ComposerSwipeDown.collapses(dx: 0, dy: 12, velocityY: 800, ended: true))
        #expect(!ComposerSwipeDown.collapses(dx: 0, dy: 4, velocityY: 2000, ended: true))
    }

    @Test func upwardAndSidewaysDragsNeverCollapse() {
        #expect(!ComposerSwipeDown.collapses(dx: 0, dy: -60, velocityY: -900, ended: true))
        #expect(!ComposerSwipeDown.collapses(dx: 60, dy: 30, velocityY: 900, ended: true))
    }
}
#endif
