import Foundation

// Gestures and moves made on a pending create's stand-in (a column width or row edge dragged, a
// tab dropped, during the New Column / New Row animation) show at once over the stand-in and name
// the daemon's objects at send time: the daemon refuses a stand-in's pane, column or row id, and
// a refusal would roll the gesture back mid-motion.
//
// A stand-in column or row id derives from its stand-in pane's handle (``ProvisionalColumn``,
// ``ProvisionalRow``): the id itself for the new column or row, with bit 61 set for the screen's
// tree column or the column's first row, which hold the create's anchor instead (and bit 60 too
// for the one column New Row makes of a split-tree screen).
extension DaemonStore {
    /// Set on a stand-in column or row id that holds the create's anchor, not its stand-in pane.
    private static let anchorBit: UInt64 = 1 << 61
    /// The bits a stand-in column or row id adds to its stand-in pane's handle.
    private static let derivedBits: UInt64 = (1 << 61) | (1 << 60)

    /// Whether `handle` is a pending create's stand-in, which no daemon command may name.
    public func isStandIn(_ handle: PaneID) -> Bool { handle.rawValue >= ProvisionalPane.firstHandle }

    /// Whether `column` is a pending New Column's stand-in column (its own or the screen's tree column).
    public func isStandIn(column: ColumnID) -> Bool { column.rawValue >= ProvisionalPane.firstHandle }

    /// The stand-in pane whose create made the stand-in column or row id `raw`; nil for a daemon id.
    func standInCreate(ofDerived raw: UInt64) -> PaneID? {
        raw >= ProvisionalPane.firstHandle ? PaneID(rawValue: raw & ~Self.derivedBits) : nil
    }

    /// The pane shown in the stand-in column or row `raw` now: the daemon's pane that took the
    /// stand-in (or the anchor) over, else the stand-in itself.
    private func paneShown(inDerived raw: UInt64) -> PaneID? {
        guard let created = standInCreate(ofDerived: raw) else { return nil }
        let pane = raw & Self.anchorBit != 0 ? standIns[created]?.anchor : created
        return pane.map { ProvisionalSplit.daemonHandle(showing: $0, in: self) ?? $0 }
    }

    /// `column` and `heights` with each stand-in id replaced by the id that shows it now: the
    /// stand-in's own while its create shows it, the daemon's once the records place the daemon's
    /// pane. Ids that are not found stay as they are.
    func shownColumnTarget(column: ColumnID, heights: [RowHeightValue]) -> ColumnTarget {
        var column = column
        var columnModel: ColumnSnapshot?
        if let pane = paneShown(inDerived: column.rawValue) {
            columnModel = screen(containing: pane)?.columns.first { $0.layout.paneIDs.contains(pane) }
            column = columnModel?.id ?? column
        }
        let heights = heights.map { value -> RowHeightValue in
            guard let pane = paneShown(inDerived: value.row.rawValue) else { return value }
            let model = columnModel ?? screen(containing: pane)?.columns.first { $0.id == column }
            guard let row = model?.rows.first(where: { $0.layout.paneIDs.contains(pane) }) else { return value }
            return RowHeightValue(row: row.id, height: value.height)
        }
        return ColumnTarget(column: column, heights: heights)
    }

    /// The daemon's ids for `column` and `heights`, at send time: at once when none is a stand-in's;
    /// for a pending New Column's or New Row's stand-in column or row, once its create's records are
    /// in the store (the daemon's column and rows hold its pane).
    ///
    /// - Throws: ``CreateTargetGone`` when a stand-in's create was refused or cancelled, or the
    ///   daemon placed its pane elsewhere: nothing the daemon knows is left to name.
    public func daemonColumnTarget(column: ColumnID, heights: [RowHeightValue]) async throws -> ColumnTarget {
        // wakeup-allow: each pass waits for the next store lift (an event), never polls.
        while true {
            let target = shownColumnTarget(column: column, heights: heights)
            let ids = [target.column.rawValue] + target.heights.map(\.row.rawValue)
            guard let created = ids.lazy.compactMap({ self.standInCreate(ofDerived: $0) }).first else { return target }
            guard let standIn = standIns[created], intentLog.contains(standIn.transaction),
                  !intentLog.wasCancelled(standIn.transaction) else { throw CreateTargetGone(pane: created) }
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                standInWaiters.append((handle: created, resume: resume))
            }
        }
    }
}
