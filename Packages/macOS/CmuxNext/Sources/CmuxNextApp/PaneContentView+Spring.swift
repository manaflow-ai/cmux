import AppKit
import CmuxNextDesign
import CmuxNextTabs

// A pane on a layout spring (a split, a close, a zoom) resizes on every display frame. Its strip is laid out
// once, at the width it rests at, and shown cut to the pane's width meanwhile (`TabStripView.shownWidth`); the
// tab bar's hover area and the strip's hover follow when the spring lands.
extension PaneContentView: PaneMotionSettling {
    /// The strip's frame width for a strip `width` wide now: on a spring that resizes the pane, its width at
    /// rest (`enclosingRestSizeChange`), the same on every frame; otherwise `width`.
    func stripLayoutWidth(shown width: CGFloat) -> CGFloat {
        guard let change = enclosingRestSizeChange else { return width }
        return max(0, width + change.width)
    }

    /// The spring landed: the frame is final, so the strip shows whole again (a landing frame the same size as
    /// the last spring frame lays nothing out by itself), and the bar's hover area and what is under the pointer
    /// are read again.
    func paneMotionDidSettle() {
        needsLayout = true
        toolbar?.view.refreshCorner()
        stripView.paneMovedInWindow()
    }
}
