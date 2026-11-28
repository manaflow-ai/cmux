public import AppKit

extension LayoutRootView {
    /// Whether `view` is the layout's own background: this view or a screen's content, where the
    /// gaps between panes show the window. A pane, its tab strip, a divider or a control is not.
    public func isBackground(_ view: NSView) -> Bool {
        view === self || screenViews.values.contains { $0 === view }
    }
}
