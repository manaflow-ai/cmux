import AppKit

/// The rows the list keeps observed (feature `sidebarRowsNearViewport`, p06-scheduler-040): the list
/// tells its ``SidebarRowFeed`` which workspace rows it draws and which of them are near its
/// viewport, as Chrome's compositor keeps only the tiles near the viewport current
/// (`cc/tiles/tile_manager.cc`). Without a feed (the feature off, a space page) nothing runs.
extension SidebarListViewComponents {
    /// Tells the row feed what the list draws: after a layout every drawn workspace row and the ones
    /// near the viewport, after a scroll only the ones near it (O(rows near)).
    func watchRows(layoutChanged: Bool) {
        guard let rowFeed else { return }
        let near = workspacesNearViewport()
        guard layoutChanged else { return rowFeed.watch(near: near) }
        // Group by Status or Folder places rows by their content: an away row's change can move it into view.
        let drawn = model.grouping.isGrouped || observesEveryRow ? nil : Set(displayed.rows.compactMap { row -> WorkspaceID? in
            if case let .workspace(id) = row.key { id } else { nil }
        })
        rowFeed.watch(drawn: drawn, near: near)
    }

    /// The workspaces of the rows on screen and one screen of overscan around them (half above, half
    /// below), and the members of an open group whose header is there: the header rolls up their states.
    func workspacesNearViewport() -> Set<WorkspaceID> {
        let rect: NSRect
        if enclosingScrollView == nil, let pageViewport {
            rect = pageViewport
        } else {
            let visible = enclosingScrollView?.contentView.bounds ?? bounds
            rect = visible.insetBy(dx: 0, dy: -visible.height / 2)
        }
        var ids = Set<WorkspaceID>()
        for index in displayed.rowIndices(from: rect.minY, to: rect.maxY) {
            switch displayed.rows[index].key {
            case let .workspace(id), let .tab(id, _):
                ids.insert(id)
            case let .group(id):
                for member in groupSubtrees[id] ?? [id] { ids.formUnion(groups[member]?.workspaces.map(\.id) ?? []) }
            default:
                break
            }
        }
        return ids
    }
}
