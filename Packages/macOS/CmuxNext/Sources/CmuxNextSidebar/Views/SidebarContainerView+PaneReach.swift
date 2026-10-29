public import AppKit
import CmuxNextDesign

// Leo 2026-10-29: "I SAID MOVE THE FUCKING SIDEBAR / NOT MOVE / ADD THE FUCKING AREA TO THE SIDEBAR TO THE RIGHT"
// (2026-10-28: "we don't need to be pushing our hover previews to the right of the sort of sidebar dragout", "the gap
// between the hover preview and the ... workspace sidebar element"). The empty gutter between the sidebar and the curved
// main pane belongs to the sidebar: the container is that much wider and the window pins the content that much closer,
// so the main pane does not move, the rows (and their hover, and the hover card beside them) reach `rowEdgeGap` from the
// pane, and the resize band sits on the new edge. The rail keeps its own width; its content pins ignore the sidebar.
extension SidebarContainerView {
    /// The gutter the standard sidebar takes as its own (`Metrics.mainPaneGutter`, 0 with a flush or edge-to-edge pane).
    /// The window's sidebar-relative content and title pins subtract this same amount.
    public static var paneReach: CGFloat { Metrics.mainPaneGutter }

    /// `paneReach` for this sidebar's style: none for the rail.
    public var paneReach: CGFloat { model.style == .rail ? 0 : Self.paneReach }

    /// Insets the clip's content-facing edge: a collapsed panel leaves the gutter strip it took empty, and the inset
    /// moves with the width so the panel slides out whole (no sliver of its row ends left in the strip).
    func setClipInset(_ inset: CGFloat, animated: Bool) {
        let (edge, constant) = side == .left ? (clipTrailing, -inset) : (clipLeading, inset)
        let other = side == .left ? clipLeading : clipTrailing
        other.constant = 0
        if animated { Motion.animator(edge, in: self).constant = constant } else { edge.constant = constant }
    }
}
