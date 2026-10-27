import CmuxNextDesign
@testable import CmuxNextLayout
import CoreGraphics
import Testing

/// Leo, 2026-10-21: the dim over unfocused panes was jarring. It stays, much subtler (content at
/// about 0.9, not 0.86), as a theme token, and eases in and out over its own short fade, longer
/// than the focus ring's (on the motion scale since Leo 2026-10-20: 120 ms and 80 ms; it was 150
/// and 100).
@MainActor @Suite struct SubtlePaneDimTests {
    /// A layout that dims its inactive panes covers them with the theme's subtle veil, 0.10.
    @Test func anUnfocusedPaneDimsToAboutNinetyPercent() {
        var style = LayoutStyle().applyingDesignMetrics()
        style.unfocusedPaneDim = UnfocusedPaneDim()
        let dim = style.inactiveDim(dimsInactive: true)
        #expect(abs(dim.amount - 0.10) < 0.0001)
    }

    /// A Ghostty `unfocused-split-opacity` the person set still wins over the token.
    @Test func aGhosttyUnfocusedSplitOpacityStillWins() {
        var style = LayoutStyle().applyingDesignMetrics()
        style.unfocusedPaneDim = UnfocusedPaneDim(unfocusedSplitOpacity: 0.7, fill: nil)
        #expect(abs(style.inactiveDim(dimsInactive: true).amount - 0.3) < 0.0001)
    }

    /// The veil has its own fade, `micro` (120 ms) at the default speed; the focus ring keeps the
    /// shorter `quick` (80 ms).
    @Test func theDimEasesOverItsOwnShortFade() throws {
        let fade = try #require(MotionFade(rawValue: "paneDim"), "a fade token for the pane dim")
        #expect(abs(fade.baseDuration - MotionScale.micro) < 0.0001)
        #expect(abs(MotionFade.focus.baseDuration - MotionScale.quick) < 0.0001)
        #expect(fade.baseDuration > MotionFade.focus.baseDuration)
    }
}
