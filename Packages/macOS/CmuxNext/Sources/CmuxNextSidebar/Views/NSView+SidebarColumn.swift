public import AppKit

extension NSView {
    /// The sidebar column this view sits in, on screen (y up), out to its visible edge: the
    /// sidebar container, plus the outer half of its border line on the content side when that
    /// line shows (the line is centered on the container's edge,
    /// `SidebarContainerView.visibleEdgeOutset`). A view in no sidebar container answers its own
    /// frame. Nil out of a window.
    ///
    /// Group and rail hover cards use this column band (`HoverCardEscapeGeometry.rowBand(row:column:)`).
    /// Workspace previews use their drawn row's fill instead, before the resize/drag edge.
    public var sidebarColumnOnScreen: CGRect? {
        guard let window else { return nil }
        var container: SidebarContainerView?
        var next: NSView? = self
        while let view = next, container == nil {
            container = view as? SidebarContainerView
            next = view.superview
        }
        guard let container else { return window.convertToScreen(convert(bounds, to: nil)) }
        var column = container.convert(container.bounds, to: nil)
        let outset = container.visibleEdgeOutset
        switch container.side {
        case .left: column.size.width += outset
        case .right:
            column.origin.x -= outset
            column.size.width += outset
        }
        return window.convertToScreen(column)
    }
}
