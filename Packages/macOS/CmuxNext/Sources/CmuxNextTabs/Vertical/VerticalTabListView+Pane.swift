public import AppKit

extension VerticalTabListView {
    /// A list of `strip`'s tabs with the strip's providers, set by the pane before its first apply: one tab
    /// menu and one empty-area menu for the strip and the list.
    public convenience init(following strip: TabStripView) {
        self.init(model: strip.model)
        contextMenuProvider = strip.contextMenuProvider
        previewProvider = strip.previewProvider
    }

    /// Shows the list, collapsed to icons or not, widening on hover or not.
    public func show(collapsed: Bool, expandsOnHover: Bool) {
        isHidden = false
        if isCollapsed != collapsed { isCollapsed = collapsed }
        if self.expandsOnHover != expandsOnHover { self.expandsOnHover = expandsOnHover }
    }

    /// Lays the list out on the leading edge of `bounds` (its pane's) and returns the width it takes from
    /// the content (its resting width: a list expanded on hover draws over the content and moves nothing).
    public func layOut(onLeadingEdgeOf bounds: NSRect) -> CGFloat {
        let width = isHoverExpanded ? max(reservedWidth, Self.expandedWidth) : reservedWidth
        let frame = NSRect(x: 0, y: 0, width: min(width, bounds.width), height: bounds.height)
        if self.frame != frame { self.frame = frame }
        return min(reservedWidth, bounds.width)
    }
}
