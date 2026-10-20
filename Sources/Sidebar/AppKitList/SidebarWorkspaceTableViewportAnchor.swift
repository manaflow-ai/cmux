import AppKit

@MainActor
struct SidebarWorkspaceTableViewportAnchor {
    let rowId: SidebarWorkspaceRenderItemID
    let offsetFromViewportTop: CGFloat

    static func capture(
        table: NSTableView,
        previousRows: [SidebarWorkspaceTableRowConfiguration],
        nextRows: [SidebarWorkspaceTableRowConfiguration]
    ) -> Self? {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return nil }

        var nextIndexById: [SidebarWorkspaceRenderItemID: Int] = [:]
        nextIndexById.reserveCapacity(nextRows.count)
        for (index, row) in nextRows.enumerated() where nextIndexById[row.id] == nil {
            nextIndexById[row.id] = index
        }

        var bestPreviousIndex: Int?
        var bestDisplacement = Int.max
        let upperBound = visible.lowerBound + visible.length
        for previousIndex in visible.lowerBound..<upperBound
        where previousRows.indices.contains(previousIndex) {
            let rowId = previousRows[previousIndex].id
            guard let nextIndex = nextIndexById[rowId] else { continue }
            let displacement = abs(nextIndex - previousIndex)
            if displacement < bestDisplacement {
                bestPreviousIndex = previousIndex
                bestDisplacement = displacement
            }
        }
        guard let previousIndex = bestPreviousIndex else { return nil }
        return Self(
            rowId: previousRows[previousIndex].id,
            offsetFromViewportTop: table.rect(ofRow: previousIndex).minY - table.visibleRect.minY
        )
    }

    func restore(
        table: NSTableView,
        rows: [SidebarWorkspaceTableRowConfiguration]
    ) {
        guard let rowIndex = rows.firstIndex(where: { $0.id == rowId }),
              let scrollView = table.enclosingScrollView else {
            return
        }
        table.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        var bounds = clipView.bounds
        bounds.origin.y = table.rect(ofRow: rowIndex).minY - offsetFromViewportTop
        clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}
