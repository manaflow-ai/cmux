import AppKit

/// The native drag image for a single-row drag that leaves the list.
///
/// Inside the list the drag has no image on purpose: the real row lifts and
/// follows the pointer (the freeform reorder session). That lift cannot
/// leave the list, so once the pointer goes to another window or into a
/// pane the drag would be invisible. There it shows a snapshot of the row,
/// taken at pickup, and it hides again when the pointer comes back.
extension SidebarWorkspaceTableController {
    struct ReorderDragGhost {
        let session: NSDraggingSession
        let image: NSImage
        var isShown = false
    }

    /// Horizontal slack around the list that still counts as over it, so a
    /// pointer grazing the edge mid-drag does not freeze the lift.
    static let reorderListSlack: CGFloat = 48

    static func reorderPointIsOverList(tablePointX: CGFloat, tableWidth: CGFloat) -> Bool {
        tablePointX >= -reorderListSlack && tablePointX <= tableWidth + reorderListSlack
    }

    /// Whether the drag should show its own image: off the list sideways,
    /// or outside the list's window altogether (another window).
    static func reorderDragShowsGhost(
        tablePointX: CGFloat,
        tableWidth: CGFloat,
        windowFrame: NSRect,
        screenPoint: NSPoint
    ) -> Bool {
        !reorderPointIsOverList(tablePointX: tablePointX, tableWidth: tableWidth)
            || !windowFrame.contains(screenPoint)
    }

    /// A picture of `row` as drawn right now.
    func reorderRowImage(tableView: NSTableView, row: Int) -> NSImage? {
        let rowRect = tableView.rect(ofRow: row)
        guard rowRect.width > 0, rowRect.height > 0,
              let representation = tableView.bitmapImageRepForCachingDisplay(in: rowRect) else { return nil }
        tableView.cacheDisplay(in: rowRect, to: representation)
        let image = NSImage(size: rowRect.size)
        image.addRepresentation(representation)
        return image
    }

    /// Takes the row's picture at pickup, before the lift restyles it.
    func prepareReorderDragGhost(session: NSDraggingSession, tableView: NSTableView, row: Int) {
        guard let image = reorderRowImage(tableView: tableView, row: row) else { return }
        reorderDragGhost = ReorderDragGhost(session: session, image: image)
    }

    /// Shows or hides the drag's own image; only touches the session when
    /// the answer changes.
    func syncReorderDragGhost(shown: Bool) {
        guard var ghost = reorderDragGhost, ghost.isShown != shown,
              let table = containerView?.tableView else { return }
        ghost.isShown = shown
        reorderDragGhost = ghost
        let image = ghost.image
        ghost.session.enumerateDraggingItems(
            options: [], for: table, classes: [NSPasteboardItem.self], searchOptions: [:]
        ) { item, _, stop in
            stop.pointee = true
            let contents = shown
                ? image
                : NSImage(size: item.draggingFrame.size, flipped: false) { _ in true }
            item.setDraggingFrame(item.draggingFrame, contents: contents)
        }
    }
}
