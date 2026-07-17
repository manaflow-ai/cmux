import AppKit

/// Owns explicit table-row heights and reconciles realized hosted cells outside rendering.
@MainActor
final class SidebarWorkspaceTableRowHeightOwner {
    private weak var tableView: NSTableView?
    private var rows: [SidebarWorkspaceTableRowConfiguration] = []
    private var rowIndexById: [SidebarWorkspaceRenderItemID: Int] = [:]
    private var cachedRowsById: [SidebarWorkspaceRenderItemID: SidebarWorkspaceTableRowConfiguration] = [:]
    private var cachedHeightsById: [SidebarWorkspaceRenderItemID: CGFloat] = [:]
    private var cachedWidthsById: [SidebarWorkspaceRenderItemID: CGFloat] = [:]
    private var preparedWidth: CGFloat?
    private var pendingRowIds: Set<SidebarWorkspaceRenderItemID> = []
    private var scheduledGeneration: UInt64?
    private var generation: UInt64 = 0
    private var isReconciling = false

    func attach(to tableView: NSTableView) {
        self.tableView = tableView
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = SidebarWorkspaceTableRowHeightCalculator().defaultWorkspaceHeight
    }

    func apply(
        rows nextRows: [SidebarWorkspaceTableRowConfiguration],
        hasStructuralChanges: Bool
    ) {
        rows = nextRows
        rowIndexById = Dictionary(uniqueKeysWithValues: nextRows.enumerated().map { ($1.id, $0) })
        let width = currentWidth()
        let previouslyMeasuredIds = Set(cachedHeightsById.keys)
        var nextCachedRows: [SidebarWorkspaceRenderItemID: SidebarWorkspaceTableRowConfiguration] = [:]
        var nextCachedHeights: [SidebarWorkspaceRenderItemID: CGFloat] = [:]
        var nextCachedWidths: [SidebarWorkspaceRenderItemID: CGFloat] = [:]
        var invalidatedIndexes = IndexSet()
        nextCachedRows.reserveCapacity(cachedRowsById.count)
        nextCachedHeights.reserveCapacity(cachedHeightsById.count)
        nextCachedWidths.reserveCapacity(cachedWidthsById.count)

        for (index, row) in nextRows.enumerated() {
            guard let cachedRow = cachedRowsById[row.id],
                  cachedRow.hasEquivalentContent(to: row),
                  cachedWidthsById[row.id] == width,
                  let cachedHeight = cachedHeightsById[row.id] else {
                if previouslyMeasuredIds.contains(row.id) {
                    invalidatedIndexes.insert(index)
                }
                continue
            }
            nextCachedRows[row.id] = cachedRow
            nextCachedHeights[row.id] = cachedHeight
            nextCachedWidths[row.id] = width
        }
        cachedRowsById = nextCachedRows
        cachedHeightsById = nextCachedHeights
        cachedWidthsById = nextCachedWidths
        preparedWidth = width > 0 ? width : nil

        if !hasStructuralChanges, !invalidatedIndexes.isEmpty {
            tableView?.noteHeightOfRows(withIndexesChanged: invalidatedIndexes)
        }
    }

    func height(ofRow rowIndex: Int, fallback: CGFloat) -> CGFloat {
        guard rows.indices.contains(rowIndex) else { return fallback }
        let row = rows[rowIndex]
        let width = currentWidth()
        guard let cachedRow = cachedRowsById[row.id],
              cachedRow.hasEquivalentContent(to: row),
              cachedWidthsById[row.id] == width,
              let cachedHeight = cachedHeightsById[row.id] else {
            return row.estimatedHeight
        }
        return cachedHeight
    }

    func observe(_ cell: SidebarWorkspaceTableCellView) {
        cell.hostedContentSizeDidInvalidate = { [weak self, weak cell] in
            guard let self, let cell, !self.isReconciling else { return }
            self.scheduleMeasurement(for: cell.representedRowId)
        }
        scheduleMeasurement(for: cell.representedRowId)
    }

    func viewportDidChange() {
        let width = currentWidth()
        guard width > 0, preparedWidth != width else { return }
        preparedWidth = width
        let measuredIds = Set(cachedHeightsById.keys)
        let invalidatedIndexes = IndexSet(rows.indices.filter { measuredIds.contains(rows[$0].id) })
        cachedRowsById.removeAll(keepingCapacity: true)
        cachedHeightsById.removeAll(keepingCapacity: true)
        cachedWidthsById.removeAll(keepingCapacity: true)
        if !invalidatedIndexes.isEmpty {
            tableView?.noteHeightOfRows(withIndexesChanged: invalidatedIndexes)
        }
        scheduleVisibleMeasurements()
    }

    private func scheduleMeasurement(for rowId: SidebarWorkspaceRenderItemID?) {
        guard let rowId else { return }
        pendingRowIds.insert(rowId)
        guard scheduledGeneration == nil else { return }
        generation &+= 1
        let scheduledGeneration = generation
        self.scheduledGeneration = scheduledGeneration
        // Intrinsic-size invalidation arrives from inside AppKit layout, which
        // has no completion callback. Reconcile on the next event turn so
        // noteHeightOfRows cannot reenter that same layout transaction.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.scheduledGeneration == scheduledGeneration else { return }
                self.scheduledGeneration = nil
                self.reconcilePendingRows()
            }
        }
    }

    private func scheduleVisibleMeasurements() {
        guard let tableView else { return }
        for rowIndex in tableView.rows(in: tableView.visibleRect).integerIndexes
            where rows.indices.contains(rowIndex) {
            scheduleMeasurement(for: rows[rowIndex].id)
        }
    }

    private func reconcilePendingRows() {
        guard let tableView else {
            pendingRowIds.removeAll(keepingCapacity: true)
            return
        }
        let rowIds = pendingRowIds
        pendingRowIds.removeAll(keepingCapacity: true)
        let width = currentWidth()
        guard width > 0 else { return }
        preparedWidth = width

        isReconciling = true
        defer { isReconciling = false }
        var changedIndexes = IndexSet()
        for rowId in rowIds {
            guard let rowIndex = rowIndexById[rowId],
                  let cell = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false)
                    as? SidebarWorkspaceTableCellView,
                  cell.representedRowId == rowId else {
                continue
            }
            let height = cell.hostedContentHeight()
            let oldHeight = cachedHeightsById[rowId] ?? rows[rowIndex].estimatedHeight
            cachedRowsById[rowId] = rows[rowIndex]
            cachedHeightsById[rowId] = height
            cachedWidthsById[rowId] = width
            if oldHeight != height {
                changedIndexes.insert(rowIndex)
            }
        }
        if !changedIndexes.isEmpty {
            tableView.noteHeightOfRows(withIndexesChanged: changedIndexes)
        }
    }

    private func currentWidth() -> CGFloat {
        tableView?.enclosingScrollView?.contentView.bounds.width ?? 0
    }
}

private extension NSRange {
    var integerIndexes: Range<Int> {
        guard location != NSNotFound else { return 0..<0 }
        return location..<(location + length)
    }
}
