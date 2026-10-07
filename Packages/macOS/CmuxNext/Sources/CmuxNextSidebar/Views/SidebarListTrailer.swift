import AppKit

/// The sections after the workspaces (Recents, `SidebarLayoutDocument.listTrail`)
/// in the list's document, right under its last row: they scroll with the
/// list, one sidebar with no gap (Leo 2026-10-06).
@MainActor final class SidebarListTrailer {
    /// The region drawing the sections.
    let region = SidebarRegionView(region: .middle)
    /// The sections' content height, set by `show`.
    private(set) var height: CGFloat = 0

    /// Draws `content` and grows the list's document to hold it.
    func show(_ content: SidebarRegionView.Content, width: CGFloat, in list: SidebarListView) {
        region.update(content, width: width)
        height = region.layoutResult.height
        list.updateDocumentHeight()
    }

    /// Puts the view under the last row of `list`, across its width.
    func place(in list: SidebarListView) {
        let view = region
        if view.superview !== list { list.addSubview(view, positioned: .above, relativeTo: list.decorations) }
        let target = NSRect(x: 0, y: list.displayed.totalHeight, width: list.frame.width, height: height)
        if view.frame != target { view.frame = target }
    }
}
