public import AppKit

/// A pane's hosted view that draws its own tools at the trailing end of the pane's tab row
/// (`ChromeTunables.tabRowTools`; Leo 2026-10-14, "why is there even a top bar"): a chat's header
/// tools. While it reports a width, the pane lays the view over the strip's row too and narrows the
/// strip by that width; the strip and the pane's own toolbar stay above the view, so the view
/// draws its tools in the space the strip gave up.
@MainActor
public protocol PaneTabRowSharing: AnyObject {
    /// Points the view's tools take at the row's trailing end, left of the pane's own toolbar;
    /// nil or 0 while it does not share the row.
    var tabRowToolsWidth: CGFloat? { get }
    /// Called whenever ``tabRowToolsWidth`` changes.
    var onTabRowToolsChange: (() -> Void)? { get set }
    /// The row the view may draw its tools in: the top `height` points (0: it does not share the
    /// row now), less `trailingInset` points at the trailing end, where the pane's own toolbar is.
    func setTabRow(height: CGFloat, trailingInset: CGFloat)
}

extension PaneTabRowSharing {
    /// Points the strip gives up beside the view's tools in a row `room` wide (at most half of it).
    public func tabRowWidth(room: CGFloat) -> CGFloat { min(max(0, tabRowToolsWidth ?? 0), max(0, room / 2)) }

    /// Offers the view the row (`height` 0: none); a change in its tools' width lays `pane` out
    /// again while the view is still in it (a view another pane took gets its row from that pane).
    public func offerTabRow(height: CGFloat, trailingInset: CGFloat, in pane: NSView) {
        onTabRowToolsChange = { [weak self, weak pane] in
            guard let pane, let view = self as? NSView, view.isDescendant(of: pane) else { return }
            pane.needsLayout = true
        }
        setTabRow(height: height, trailingInset: height > 0 ? trailingInset : 0)
    }
}
