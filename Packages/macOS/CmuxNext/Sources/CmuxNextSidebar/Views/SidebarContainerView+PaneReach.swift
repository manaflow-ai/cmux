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

    /// Keeps the curved-card edge line in the titlebar band, above the card: the row-to-card gap
    /// stays plain sidebar background, and flat styles keep the full-height line. `rootY` is in the
    /// container's superview coordinates, which is also where the main-pane card frame is reported.
    public func updateResizeLine(cardMaxY rootY: CGFloat) {
        // Debug `sidebar.cornerMorph`: the tint parts sidebar and content, and the line would cut the joins.
        guard !cornerMorphHidesLine else {
            handle.lineMinY = .greatestFiniteMagnitude
            return
        }
        guard Metrics.mainPaneCurved else {
            handle.lineMinY = 0
            return
        }
        guard let root = superview else { return }
        handle.lineMinY = handle.convert(CGPoint(x: 0, y: rootY), from: root).y
    }

    /// The sidebar's on-screen share of its width, 0 to 1: its animated frame over the user's width
    /// (the window's toolbar band opens in step with it, cx-uxdr).
    public var onScreenShare: CGFloat {
        let width = model.width
        guard width > 0 else { return model.isHidden ? 0 : 1 }
        return min(1, max(0, frame.width / width))
    }

    /// The container's frame in `view`'s coordinates (the window's for nil), widened by the visible
    /// pane reach on the edge that faces the content.
    public func visualFrame(in view: NSView?) -> CGRect {
        var rect = convert(bounds, to: view)
        let reach = visualPaneReach
        guard reach > 0 else { return rect }
        if side == .right { rect.origin.x -= reach }
        rect.size.width += reach
        return rect
    }

    /// The sidebar's rect for the window's overlay occluder (window coordinates, the visible pane
    /// reach included), so pages and pane overlays stay under the whole surface; nil while it is
    /// collapsed or hidden.
    public var occluderRectInWindow: CGRect? {
        frame.width > 0.5 && !isHidden ? visualFrame(in: nil) : nil
    }

    /// Routes the root view's hit test into the pane reach. `hit` is the root's own result for
    /// `point` (in `root`'s coordinates, this container's superview). Root siblings such as the
    /// resize handle keep their z-order: only a point the root itself took (`hit === root`) in the
    /// visible reach band beyond this container's frame goes to the sidebar's extended panel.
    public func routePaneReach(_ hit: NSView?, at point: NSPoint, in root: NSView) -> NSView? {
        guard hit === root, !isHidden, visualPaneReach > 0, visualFrame(in: root).contains(point),
              !convert(bounds, to: root).contains(point) else { return hit }
        return hitTest(point) ?? hit
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
