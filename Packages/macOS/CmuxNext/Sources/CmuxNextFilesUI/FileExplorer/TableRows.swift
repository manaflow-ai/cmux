package import AppKit
package import CmuxVisibleRows

/// A table's rows, moved from one list to the next by each row's stable id: rows that left are
/// removed, new rows inserted, kept rows whose value changed reloaded, and unchanged rows not
/// touched (`reloadData()` configures every shown row again). The Files tree and Find results.
@MainActor
package final class TableRows<Row: Equatable, ID: Hashable> {
    /// The most rows that may come or go in one update; past it the table reloads whole.
    package static var diffLimit: Int { 2_000 }

    /// The rows shown, in order.
    package private(set) var all: [Row] = []
    /// Row views configured (``configure(_:)``), for count tests.
    package private(set) var configured = 0
    /// Whole-table reloads (a new folder, a new search: no row kept).
    package private(set) var fullReloads = 0
    /// The table's row work for the visible-rows contract: each configure, each cell layout
    /// (``laidOut()``), and the rows each ``show(_:in:)`` compares.
    package let listWork = ListWorkMeter()
    private let id: (Row) -> ID

    // A generic main-actor class: an isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    package init(id: @escaping (Row) -> ID) {
        self.id = id
    }

    package var count: Int { all.count }
    package subscript(index: Int) -> Row { all[index] }

    /// The row a row view shows, counted.
    package func configure(_ index: Int) -> Row {
        configured += 1
        listWork.configured()
        return all[index]
    }

    /// One cell of this table laid out (a width change, a reload).
    package func laidOut() { listWork.laidOut() }

    /// Shows `new` in `table`, whose data source answers from these rows.
    package func show(_ new: [Row], in table: NSTableView) {
        let old = all
        all = new
        // Every row is compared: the model hands over a whole new list (FileExplorerModel.rebuild).
        listWork.walked(old.count + new.count)
        let columns = IndexSet(integersIn: 0..<max(table.numberOfColumns, 1))
        switch RowDiff.between(old, new, id: id, limit: Self.diffLimit) {
        case .reloadAll:
            fullReloads += 1
            table.reloadData()
        case .update(let removed, let inserted, let changed):
            if !removed.isEmpty || !inserted.isEmpty {
                table.beginUpdates()
                table.removeRows(at: IndexSet(removed), withAnimation: [])
                table.insertRows(at: IndexSet(inserted), withAnimation: [])
                table.endUpdates()
            }
            if !changed.isEmpty { table.reloadData(forRowIndexes: IndexSet(changed), columnIndexes: columns) }
        }
    }
}
