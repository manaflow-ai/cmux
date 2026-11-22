import AppKit
import CmuxNextDesign

/// Keeps the sidebar's scrollers clear of the resize band (https://github.com/manaflow-ai/cmux/issues/49654).
///
/// A ``ThinScroller`` takes every press in its 14 pt strip at the scroll view's trailing edge
/// (`grabZone`). On a left sidebar that edge is the divider, and the sidebar's surface reaches past
/// it into the main pane's gutter, so the strip lay under the whole resize band: wherever the list
/// overflowed, a press on the edge scrolled instead of resizing. The container gives the distance
/// from this view's trailing edge to the band's inner edge (``dividerScrollerClearance``); every
/// scroll view that runs to that edge insets its scroller by it, so the scroller ends where the band
/// begins and the two never share a point. The band takes every press on it, the resize cursor
/// shows across it, and the knob stays fully grabbable beside it.
extension SidebarView {
    /// The scroll views whose vertical scroller sits at this view's trailing edge.
    var dividerEdgeScrollViews: [NSScrollView] {
        [scrollView, aboveScroll, belowScroll, priorityPanelView.scrollView]
    }

    /// The sidebar's grab zone beside the band: the wide knob and 1 pt, the knob flush against the band.
    static var dividerScrollerGrab: CGFloat { ThinScroller.expandedKnobThickness + 1 }

    /// Insets each edge scroller by ``dividerScrollerClearance`` from the trailing edge. Beside the
    /// band the scroller grabs only the wide knob's column (``dividerScrollerGrab``), so it takes no
    /// more of a row's trailing button than the full strip at the edge did; with no clearance (a right
    /// sidebar) it keeps the shared scroller's geometry.
    func applyDividerScrollerClearance() {
        let clear = dividerScrollerClearance > 0
        for scroll in dividerEdgeScrollViews {
            if scroll.scrollerInsets.right != dividerScrollerClearance {
                var insets = scroll.scrollerInsets
                insets.right = dividerScrollerClearance
                scroll.scrollerInsets = insets
                scroll.tile()
            }
            guard let scroller = scroll.verticalScroller as? ThinScroller else { continue }
            scroller.knobEdgeInset = clear ? 0 : 2
            scroller.grabThickness = clear ? Self.dividerScrollerGrab : nil
        }
    }
}
