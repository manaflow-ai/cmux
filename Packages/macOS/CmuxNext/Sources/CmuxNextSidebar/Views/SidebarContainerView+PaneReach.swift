public import AppKit
import CmuxNextDesign

// The card's gutter is shared with the sidebar surface. The sidebar owns the part of that
// gutter which follows its rows, leaving the one named row-to-card gap before the card itself.
// Keeping this geometry here means the standard sidebar and its hover-card column use the same edge.
extension SidebarContainerView {
    /// The amount of the curved pane gutter the standard sidebar surface reaches into.
    ///
    /// A row ends `SidebarStyle.rowEdgeGap` before the surface edge. The remaining distance to the
    /// card is the scaled `SidebarStyle.rowToPaneGap`. Flat styles have no pane gutter and retain
    /// their existing width and edge.
    public static var paneReach: CGFloat {
        max(0, Metrics.mainPaneGutter + SidebarStyle.rowEdgeGap - SidebarStyle.rowToPaneGap)
    }

    /// Rail content is an overlay and does not take space from the pane.
    public var paneReach: CGFloat { model.style == .rail ? 0 : Self.paneReach }

    /// Keeps the curved-card edge line in the titlebar band. `rootY` is in the container's
    /// superview coordinates, which is also where the main-pane card frame is reported.
    public func updateResizeLine(cardMaxY rootY: CGFloat) {
        guard Metrics.mainPaneCurved else {
            handle.lineMinY = 0
            return
        }
        guard let root = superview else { return }
        handle.lineMinY = handle.convert(CGPoint(x: 0, y: rootY), from: root).y
    }

    /// Expands the clip into the pane gutter while the panel is shown. When the panel collapses,
    /// the clip gives that reach back so no sliver of a row remains visible at width zero.
    func setClipReach(_ reach: CGFloat, collapsed: Bool, animated: Bool) {
        let amount = collapsed ? 0 : reach
        let edge: NSLayoutConstraint
        let other: NSLayoutConstraint
        if side == .left {
            edge = clipTrailing
            other = clipLeading
            other.constant = 0
        } else {
            edge = clipLeading
            other = clipTrailing
            other.constant = 0
        }
        let target = amount * (side == .left ? 1 : -1)
        if animated { Motion.animator(edge, in: self).constant = target } else { edge.constant = target }
    }
}
