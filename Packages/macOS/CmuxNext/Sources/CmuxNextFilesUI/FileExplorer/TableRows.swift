package import AppKit

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
        return all[index]
    }

    /// Shows `new` in `table`, whose data source answers from these rows.
    package func show(_ new: [Row], in table: NSTableView) {
        let old = all
        all = new
        let oldIDs = old.map(id), newIDs = new.map(id)
        let columns = IndexSet(integersIn: 0..<max(table.numberOfColumns, 1))
        if oldIDs == newIDs {
            let changed = IndexSet(new.indices.filter { old[$0] != new[$0] })
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: columns) }
            return
        }
        let kept = Set(oldIDs)
        let added = newIDs.reduce(0) { kept.contains($1) ? $0 : $0 + 1 }
        let shared = new.count - added
        guard shared > 0, added + (old.count - shared) <= Self.diffLimit else {
            fullReloads += 1
            table.reloadData()
            return
        }
        var removed = IndexSet(), inserted = IndexSet()
        for change in newIDs.difference(from: oldIDs) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        table.beginUpdates()
        table.removeRows(at: removed, withAnimation: [])
        table.insertRows(at: inserted, withAnimation: [])
        table.endUpdates()
        // Kept rows keep their order: pair them up and reload the ones whose value changed.
        var changed = IndexSet()
        var oldIndex = 0
        for newIndex in new.indices where !inserted.contains(newIndex) {
            while removed.contains(oldIndex) { oldIndex += 1 }
            if old[oldIndex] != new[newIndex] { changed.insert(newIndex) }
            oldIndex += 1
        }
        if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: columns) }
    }
}
