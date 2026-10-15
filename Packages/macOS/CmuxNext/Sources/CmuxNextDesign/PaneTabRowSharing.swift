public import CoreGraphics

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
