public import CoreGraphics

/// The camera of one screen, kept while its workspace is unmounted and given back when it mounts
/// again (`WorkspaceViewRecord`): the column strip's offset (nil on a split screen),
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
    /// Where every screen's scrolls settle now, for the screens the layout has; a screen not built
    /// yet at what it was given. A screen with no offset has no entry.
    public func scrollRecords() -> [ScreenID: LayoutScreenScroll] {
        var records: [ScreenID: LayoutScreenScroll] = [:]
        if !pendingScreenScrolls.isEmpty {
            let live = Set(model.screens.map(\.id))
            for (id, record) in pendingScreenScrolls where live.contains(id) { records[id] = record }
        }
        for (id, view) in screenViews {
            let record = view.scrollRecord()
            if record != LayoutScreenScroll() { records[id] = record }
        }
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
    /// The frames were computed at a real size, so the scroll targets are where the person saw
    /// them. A screen built while its root was zero-sized and hidden since (another screen shows)
    /// has none: its reducers placed the camera against a zero viewport.
    var hasSizedGeometry: Bool { baseGeometry.viewport.width > 0 && baseGeometry.viewport.height > 0 }

    /// Where each scroll settles. A screen that never laid out at a size records only what a
    /// restore gave it, so it mounts again with the first placement its mode gives, as a fresh mount.
    func scrollRecord() -> LayoutScreenScroll {
        let sized = hasSizedGeometry
        var record = pendingScroll
        if geometry.isColumns { record.strip = scrollState.pendingRestore ?? (sized ? scroll.target : nil) }
        for (id, row) in rowScrolls { record.rows[id] = row.state.pendingRestore ?? (sized ? row.state.spring.target : nil) }
        for (id, area) in areaScrolls { record.areas[id] = area.state.pendingRestore ?? (sized ? area.state.spring.target : nil) }
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
        guard hasSizedGeometry, !needsReconcileOnShow else { return }
        motionTurn { syncScroll(focused: lastFocused, source: .programmatic, mode: context.model.centerFocusedColumn, animated: false) }
    }

    /// The saved row and area offsets go once the screen synced at a real size: a scroll built
    /// later (a column that starts to overflow) is new, not the one that was saved.
    func dropPendingScrollIfSized() {
        guard hasSizedGeometry, pendingScroll != LayoutScreenScroll() else { return }
        pendingScroll = LayoutScreenScroll()
    }
}
