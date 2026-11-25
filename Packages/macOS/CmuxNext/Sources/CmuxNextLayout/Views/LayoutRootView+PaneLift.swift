public import AppKit

/// Whole-pane drag (RFD 0022 item 2): the dragged pane's own host follows the pointer at full size with its live
/// content. The host's frame moves, not a layer transform: a Chromium page is a child window a transform does not reach.
/// The drop target and its preview are a tab drag's (`updateTabDrag`); the layout is untouched until the drop commits.
extension LayoutRootView {
    /// Carries `pane` by how far the pointer moved from `start` to `current` (window coordinates). One placement of
    /// that host per event: the host's origin changes, its size and content do not (no layout pass, no resize).
    public func liftPane(_ pane: PaneID, from start: NSPoint, to current: NSPoint) { // perf-hot: 4ms motion-frame
        guard let active = model.activeScreenID, let view = screenViews[active] else { return }
        let a = view.convert(start, from: nil), b = view.convert(current, from: nil)
        let first = view.lift?.pane != pane
        view.lift = (pane, CGVector(dx: b.x - a.x, dy: b.y - a.y))
        if first, let host = view.context.hosts[pane], host.superview === view {
            host.layer?.zPosition = 1
            view.addSubview(host, positioned: .above, relativeTo: nil)
        }
        view.applyPresentation(force: false)
    }

    /// Puts the lifted pane back at its rest frame (a cancel, or a drop's own commit placing it).
    public func dropPaneLift() {
        for view in screenViews.values {
            guard let lifted = view.lift?.pane else { continue }
            view.lift = nil
            view.context.hosts[lifted]?.layer?.zPosition = 0
            view.applyPresentation(force: true)
        }
    }
}
