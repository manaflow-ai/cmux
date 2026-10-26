public import CoreGraphics

/// The camera of one screen, kept while its workspace is unmounted and given back when it mounts
/// again (`WorkspaceViewRecord`, p07-memory-033): the column strip's offset (nil on a split screen),
/// each overflowing row column's and each scroll area's. Content-space offsets where each scroll
/// settles; a remount clamps them to its layout and still reveals the focused pane.
public nonisolated struct LayoutScreenScroll: Hashable, Sendable {
    public var strip: CGFloat?
    public var rows: [ColumnID: CGFloat]
    public var areas: [SplitID: CGFloat]

    public init(strip: CGFloat? = nil, rows: [ColumnID: CGFloat] = [:], areas: [SplitID: CGFloat] = [:]) {
        self.strip = strip
        self.rows = rows
        self.areas = areas
    }
}

extension LayoutRootView {
    /// Where every screen's scrolls settle now; a screen not built yet at what it was given.
    public func scrollRecords() -> [ScreenID: LayoutScreenScroll] {
        var records = pendingScreenScrolls
        for (id, view) in screenViews { records[id] = view.scrollRecord() }
        return records
    }

    /// Gives each screen its saved camera. A screen view takes it at its first sync with a real
    /// viewport, so a root mounted out of its window rests there in the first frame it draws; a
    /// screen not built yet takes it when it is (`syncWithModel`).
    public func restoreScroll(_ records: [ScreenID: LayoutScreenScroll]) {
        for (id, record) in records {
            if let view = screenViews[id] { view.restoreScroll(record) } else { pendingScreenScrolls[id] = record }
        }
    }
}

extension ScreenContentView {
    func scrollRecord() -> LayoutScreenScroll {
        var record = pendingScroll
        if geometry.isColumns { record.strip = scrollState.pendingRestore ?? scroll.target }
        for (id, row) in rowScrolls { record.rows[id] = row.state.pendingRestore ?? row.state.spring.target }
        for (id, area) in areaScrolls { record.areas[id] = area.state.pendingRestore ?? area.state.spring.target }
        return record
    }

    /// Each scroll rests at `record` from its next sync with a real viewport: the strip's and the
    /// built row and area scrolls' now, the others when `syncRows` and `syncAreas` build them.
    func restoreScroll(_ record: LayoutScreenScroll) {
        scrollState.pendingRestore = record.strip
        pendingScroll = LayoutScreenScroll(rows: record.rows, areas: record.areas)
        for (id, offset) in record.rows where rowScrolls[id] != nil {
            rowScrolls[id]?.state.pendingRestore = offset
            pendingScroll.rows[id] = nil
        }
        for (id, offset) in record.areas where areaScrolls[id] != nil {
            areaScrolls[id]?.state.pendingRestore = offset
            pendingScroll.areas[id] = nil
        }
        // Already laid out at its size: rest there now. Otherwise its first sized layout does.
        guard reconciledScale != nil, bounds.width > 0, bounds.height > 0, !needsReconcileOnShow else { return }
        motionTurn { syncScroll(focused: lastFocused, source: .programmatic, mode: context.model.centerFocusedColumn, animated: false) }
    }

    /// The saved row and area offsets go once the screen synced at a real size: a scroll built
    /// later (a column that starts to overflow) is new, not the one that was saved.
    func dropPendingScrollIfSized() {
        guard bounds.width > 0, bounds.height > 0, pendingScroll != LayoutScreenScroll() else { return }
        pendingScroll = LayoutScreenScroll()
    }
}
