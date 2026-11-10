import Observation

/// One observable cell per workspace id (the public id `ws_…`, or the key) that a wait reads
/// (main-thread-scheduling.md section 3, O9: "wait on the one id (a per-id cell), not on the list"). A lookup by id that a wait re-runs under observation reads
/// its id's cell (``read(_:)``), and the index touches the cell each time it keys a workspace under that id or drops it
/// (``touch(_:)``). A wait for one id is woken by that id only: never by a change of another workspace, and never by
/// a walk of the list.
///
/// A cell lives from the first read of its id to the next touch: the touch wakes every observer of it, and an observer
/// that runs again reads a new cell. So the map holds only ids that a running wait asks about and that did not move
/// since; an id read by a wait that was cancelled first keeps its cell (a few per connection, a few bytes each).
@MainActor final class IDWaitCells<ID: Hashable> {
    private var cells: [ID: IDWaitCell] = [:]

    /// A generic main-actor class: its implicit isolated deinit crashes the Release optimizer (Swift 6.3.3).
    nonisolated deinit {}

    /// Reads `id`'s cell: a tracked caller is woken when the index keys or drops a record under `id`.
    func read(_ id: ID) {
        if let cell = cells[id] {
            _ = cell.revision
            return
        }
        let cell = IDWaitCell()
        cells[id] = cell
        _ = cell.revision
    }

    /// The index keyed or dropped a record under `id`: wakes the observers of its cell (none read: nothing to do).
    func touch(_ id: ID) {
        guard let cell = cells.removeValue(forKey: id) else { return }
        cell.revision &+= 1
    }
}

/// The observable counter of one id (``IDWaitCells``).
@Observable @MainActor final class IDWaitCell {
    var revision: UInt64 = 0
}
