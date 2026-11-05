import AppKit
import CmuxNextDesign

// Thunderdome r2 B, "squared" (`SquaredTabCorner`, Debug Settings `chrome.squaredTab`; Leo 2026-11-05: "the
// tab at its left, when it's at the leftmost on that left area, is just square"). The strip that starts on
// the sidebar's edge (the main pane card's leading edge, with the sidebar shown on that side) starts its first
// tab on the edge itself, square on that side, so the edge's straight line runs into the tab's straight side.
// Its other corners, and every other tab, keep the strip's radius. A strip under the traffic lights (the
// sidebar hidden) or in a pane further right keeps today's inset.
extension TabStripView {
    /// The anchor's leading edge in this strip's coordinates when the strip starts on it: no more
    /// than the strip's own padding and a pane's padding in from it. Nil when the look is off, no
    /// sidebar is beside the edge (hidden, or on the other side), or the strip clears the traffic lights.
    func computeLeadingTabEdge() -> CGFloat? {
        guard metrics.squaresLeadingTab, windowControlsInset == 0 else { return nil }
        var ancestor = superview
        while let view = ancestor, !(view is any LeadingTabEdgeAnchor) { ancestor = view.superview }
        guard let anchor = ancestor as? any LeadingTabEdgeAnchor, let window else { return nil }
        // The sidebar is beside the card's leading edge when the card starts past the window's gutter; a hidden
        // sidebar or one on the right leaves the card at the window's edge (the traffic lights' case returned above).
        let cardInWindow = anchor.convert(anchor.bounds, to: nil)
        guard cardInWindow.minX > Metrics.mainPaneGutter + 1, cardInWindow.maxX <= window.frame.width - Metrics.mainPaneGutter + 1 else { return nil }
        let edge = convert(NSPoint(x: anchor.bounds.minX, y: anchor.bounds.minY), from: anchor).x
        let reach = metrics.stripHorizontalPadding + Metrics.panePadding + 0.5
        guard edge <= 0.5, -edge <= reach else { return nil }
        return edge
    }

    /// Squares the leading corners of the tab that starts the strip while it starts on the sidebar's
    /// edge; every other cell keeps all four. A tab that scrolls under the edge is cut square by the
    /// clip there.
    func squareLeadingTab() {
        var lead: TabID?
        if leadingTabEdge != nil {
            var minX = CGFloat.infinity
            for (id, _) in cells where !dying.contains(id) {
                guard let place = placed[id], place.x < minX else { continue }
                (lead, minX) = (id, place.x)
            }
            if minX > 0.5 { lead = nil }
        }
        for (id, cell) in cells { cell.squaresLeadingCorners = id == lead }
    }
}
