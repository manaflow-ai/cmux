public import AppKit

/// A pane's displayed frame and the part of the screen where it may show,
/// in the layout root's coordinates (agent cursor visibility).
public struct LayoutPaneVisibility: Equatable, Sendable {
    /// The displayed frame; off the viewport for a column scrolled out.
    public var frame: CGRect
    /// The strip area not under docked columns (strip panes), or the
    /// screen (docked panes).
    public var clip: CGRect
}

extension LayoutRootView {
    /// `pane`'s frame and clip on the active screen; nil when the pane is
    /// not on the active screen or not measured yet.
    public func visibility(of pane: PaneID) -> LayoutPaneVisibility? {
        guard let active = model.activeScreenID, let view = screenViews[active], !view.isHidden,
              let rect = view.displayedFrame(of: pane) else { return nil }
        let clip = view.geometry.scrolls(pane: pane) ? view.uncoveredRect : view.bounds
        return LayoutPaneVisibility(frame: convert(rect, from: view), clip: convert(clip, from: view))
    }
}
