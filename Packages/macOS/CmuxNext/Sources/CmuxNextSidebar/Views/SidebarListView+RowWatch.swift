import AppKit

/// The rows the list keeps current (feature `sidebarRowsNearViewport`): the list
/// tells its ``SidebarRowFeed`` which workspace rows it draws and which of them it shows, as Chrome's
/// compositor keeps only the tiles near the viewport current (`cc/tiles/tile_manager.cc`). Without a
/// feed (the feature off, a space page) nothing runs.
extension SidebarListViewComponents {
    /// Tells the row feed what the list draws: after a layout every drawn workspace row and the ones it
    /// shows, after a scroll only the ones it shows (O(rows near)). A row that comes on screen stale is
    /// mapped and patched in this call, before the frame commits.
    func watchRows(layoutChanged: Bool) {
        guard let rowFeed else { return }
        if layoutChanged { rollUpWatch = nil }
        let shown = shownWorkspaces()
        guard layoutChanged else { return rowFeed.watch(shown) }
        // Rows placed or listed by their content (Group by Status or Folder, a filter, the rail's marks): an
        // off-screen row's change can move it into view or out of the list, so every row stays armed.
        // `isFiltering` without running the filter: a query with a word (`SidebarFilter.matches`).
        let filtering = model.filterText.contains { !$0.isWhitespace }
        let readsEveryRow = model.grouping.isGrouped || filtering || observesEveryRow
        let drawn = readsEveryRow ? nil : Set(displayed.rows.compactMap { row -> WorkspaceID? in
            if case let .workspace(id) = row.key { id } else { nil }
        })
        rowFeed.watch(drawn: drawn, shown)
    }

    /// The workspaces of the rows on screen; of those on screen and in one screen of overscan around
    /// it (half above, half below); and of the members of each open group whose header is on screen,
    /// which the header rolls up.
    func shownWorkspaces() -> SidebarRowFeed.Viewport {
        let visible: NSRect, near: NSRect
        if enclosingScrollView == nil, let pageViewport {
            (visible, near) = (pageViewport, pageViewport)
        } else {
            visible = enclosingScrollView?.contentView.bounds ?? bounds
            near = visible.insetBy(dx: 0, dy: -visible.height / 2)
        }
        var shown = SidebarRowFeed.Viewport()
        var headers: [GroupID] = []
        for index in displayed.rowIndices(from: near.minY, to: near.maxY) {
            let row = displayed.rows[index]
            // Half-open: a row that only touches an edge is outside.
            guard row.y < near.maxY, row.y + row.height > near.minY else { continue }
            let onScreen = row.y < visible.maxY && row.y + row.height > visible.minY
            switch row.key {
            case let .workspace(id), let .tab(id, _):
                shown.near.insert(id)
                if onScreen { shown.visible.insert(id) }
            case let .group(id) where onScreen:
                headers.append(id)
            default:
                break
            }
        }
        shown.rollUp = rollUpMembers(of: headers)
        return shown
    }

    /// The members of `headers`' subtrees, kept while the same headers stay on screen in one layout: a
    /// scroll under one header builds no set, and the feed compares the same set in O(1).
    private func rollUpMembers(of headers: [GroupID]) -> Set<WorkspaceID> {
        if let rollUpWatch, rollUpWatch.headers == headers { return rollUpWatch.members }
        var members = Set<WorkspaceID>()
        for id in headers {
            for member in groupSubtrees[id] ?? [id] { members.formUnion(groups[member]?.workspaces.map(\.id) ?? []) }
        }
        rollUpWatch = (headers, members)
        return members
    }
}
