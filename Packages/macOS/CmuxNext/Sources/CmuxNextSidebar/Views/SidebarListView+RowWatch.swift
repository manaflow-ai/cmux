import AppKit

/// Connects realized sidebar geometry to the opt-in near-viewport row observation experiment.
extension SidebarListViewComponents {
    func watchRows(layoutChanged: Bool) {
        guard let rowFeed else { return }
        let near = workspacesNearViewport()
        guard layoutChanged else {
            rowFeed.watch(near: near)
            return
        }
        // Grouping and filtering make off-screen row content affect placement, so retain the
        // existing all-row observation policy for those layouts.
        let drawn = model.grouping.isGrouped || model.isFiltering ? nil : Set(displayed.rows.compactMap { row -> WorkspaceID? in
            if case let .workspace(id) = row.key { return id }
            return nil
        })
        rowFeed.watch(drawn: drawn, near: near)
    }

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
            case let .workspace(id):
                ids.insert(id)
            case let .tab(id, _):
                ids.insert(id)
            case let .group(id):
                for member in groupSubtrees[id] ?? [id] {
                    ids.formUnion(groups[member]?.workspaces.map(\.id) ?? [])
                }
            default:
                break
            }
        }
        return ids
    }
}
