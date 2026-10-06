import AppKit

/// The sections after the workspaces (Recents, `SidebarLayoutDocument.listTrail`)
/// in the list's document, right under its last row: they scroll with the
/// list, one sidebar with no gap (Leo 2026-10-06).
@MainActor final class SidebarListTrailer {
    /// The view drawing the sections (the sidebar's trail region).
    var view: NSView?
    /// The sections' content height; the sidebar sets it on layout.
    var height: CGFloat = 0

    /// Puts the view under the last row of `list`, across its width.
    func place(in list: SidebarListView) {
        guard let view else { return }
        if view.superview !== list { list.addSubview(view, positioned: .above, relativeTo: list.decorations) }
        let target = NSRect(x: 0, y: list.displayed.totalHeight, width: list.frame.width, height: height)
        if view.frame != target { view.frame = target }
    }
}
