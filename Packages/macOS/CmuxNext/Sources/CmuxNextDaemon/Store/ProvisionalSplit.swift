import Foundation

/// The overlay of a split intent (`Intent.splitPane`, plans/cmux-next/remote-state-ownership.md
/// S3): the provisional pane is inserted after the target leaf, as `split` does in cmux-tui
/// (`split_kind.rs`, the target's column tree and the screen's tree), with one terminal tab under
/// the client-minted ids. Undone exactly; never applied once the daemon has a pane with the same
/// public id, so the two never show side by side. The daemon reports that pane (`pane-added`)
/// before the layout that places it (`layout-changed`): in between, the split places the
/// daemon's pane instead, so the screen never shows unsplit (cx-ry0y).
///
/// The echo does no work (perf I3, plans/cmux-next/perf-speed-of-light.md): the provisional pane
/// is one `PaneModel` for the intent's whole life, and the daemon's pane-added updates that same
/// object in place (``DaemonStore/confirmedPane(_:)``), so every observer keeps its model. The
/// split goes out under the provisional split's public id (`split-client-split-id-v1`), so the
/// daemon's layout names the split the window already shows.
@MainActor struct ProvisionalSplit {
    /// Whether the daemon's records hold that pane and a screen's layout places it: the split
    /// has nothing left to show.
    static func daemonPlaces(_ provisional: ProvisionalPane, in store: DaemonStore) -> Bool {
        guard let pane = daemonPane(provisional, in: store) else { return false }
        return store.screen(containing: pane.handle)?.layout.paneIDs.contains(pane.handle) == true
    }

    /// Whether the split's daemon pane reached the records and left them before any layout
    /// placed it (its tab moved out and the pane closed, or a terminal split's pane closed): the
    /// daemon made the split and undid it, so the split shows nothing and waits for nothing.
    /// The pane must be gone when this is read, so a close and re-add in one batch is no close.
    /// A close and a re-add in two batches does not happen: the pane's public id is minted for
    /// this one split and sent once, and the daemon takes a client pane id only from that split's
    /// reservation (`pane_id_exists` refuses one in use); every other pane it makes gets a fresh
    /// id, and a restart's panes come back in a new connection's snapshot, not as events.
    static func paneGone(_ intent: PendingIntent, in store: DaemonStore) -> Bool {
        guard intent.daemonPaneSeen, case .splitPane(_, _, _, let provisional) = intent.kind else { return false }
        return daemonPane(provisional, in: store) == nil
    }

    /// A snapshot that holds a pending split's daemon pane counts as its `pane-added`: a split not
    /// replied to yet can see its pane only through a resync snapshot, and must still settle when
    /// an event closes that pane later (``paneGone(_:in:)``).
    static func noteDaemonPanes(in store: DaemonStore) {
        guard !store.intentLog.isEmpty else { return }
        for entry in store.intentLog.entries {
            guard case .splitPane(_, _, _, let provisional) = entry.kind, daemonPane(provisional, in: store) != nil else { continue }
            store.intentLog.noteDaemonPane(provisional.paneID)
        }
    }

    /// A split stays until the daemon's layout places its pane (cx-ry0y): `pane-added` and the
    /// `layout-changed` that places it can land after the reply's settle sequence, and undoing
    /// the split before them showed the pane unsplit for one turn. One whose pane is gone again
    /// (``paneGone(_:in:)``) settles at once: waiting for a snapshot left it applying, and its
    /// provisional pane came back. A cancelled creation stays while the records hold what it
    /// made (``CancelledCreation``).
    static func awaitsRecords(_ intent: PendingIntent, in store: DaemonStore) -> Bool {
        if intent.closeWhenCreated { return CancelledCreation.daemonHolds(intent, in: store) }
        switch intent.kind {
        case .splitPane(_, _, _, let provisional):
            return !daemonPlaces(provisional, in: store) && !paneGone(intent, in: store)
        case .closeTabs(let surfaces):
            return TabCloseOverlay(store: store).daemonHolds(surfaces)
        case .createWorkspace(let provisional, _):
            // Cmd-N's workspace settles only once the daemon's workspace holds a tab: before
            // that, undoing the overlay would show the window an empty workspace for a turn.
            guard let workspace = store.workspacesByKey[provisional.key] else { return true }
            return !workspace.screens.contains { $0.panes.contains { !$0.tabs.isEmpty } }
        default:
            return false
        }
    }

    /// The pane a pending create's command addresses: `handle`, or, for a stand-in pane, the daemon's
    /// pane that took it over (nil until the daemon reports it): under the same public id for a split's
    /// stand-in, the pane holding the first tab of the workspace with the same key for Cmd-N's.
    static func daemonHandle(showing handle: PaneID, in store: DaemonStore) -> PaneID? {
        if let origin = store.standInTargets[handle] ?? standInOrigin(of: handle, in: store) {
            return daemonPane(of: origin, showing: handle, in: store)
        }
        return store.panesByHandle[handle] != nil ? handle : nil
    }

    /// The daemon's pane that took over the stand-in `handle` made by `origin`; nil before.
    static func daemonPane(of origin: StandInOrigin, showing handle: PaneID, in store: DaemonStore) -> PaneID? {
        switch origin {
        case .pane(let paneID):
            return store.index.panesByResource[ResourceID(rawValue: paneID)].flatMap { $0.handle != handle ? $0.handle : nil }
        case .workspace(let key):
            return ProvisionalWorkspaceOverlay.adoptedPane(of: key, in: store)
        }
    }

    /// What made stand-in `handle`: a pending split's (or column's, row's) provisional pane, the first pane of a
    /// pending Cmd-N workspace, or of one whose create succeeded (``DaemonStore/adoptedStandIn(_:)``).
    static func standInOrigin(of handle: PaneID, in store: DaemonStore) -> StandInOrigin? {
        guard handle.rawValue >= ProvisionalPane.firstHandle else { return nil }
        for entry in store.intentLog.entries {
            switch entry.kind {
            case .splitPane(_, _, _, let provisional) where provisional.handle == handle: return .pane(provisional.paneID)
            case .createWorkspace(let provisional, _) where provisional.pane == handle: return .workspace(provisional.key)
            default: continue
            }
        }
        return store.adoptedStandIn(handle).map(StandInOrigin.workspace)
    }

    /// Whether the create that makes a stand-in of `origin` is still in flight (in the log, not closed by the person).
    static func createInFlight(_ origin: StandInOrigin, in store: DaemonStore) -> Bool {
        store.intentLog.entries.contains { entry in
            guard !entry.closeWhenCreated else { return false }
            switch (entry.kind, origin) {
            case (.splitPane(_, _, _, let provisional), .pane(let paneID)): return provisional.paneID == paneID
            case (.createWorkspace(let provisional, _), .workspace(let key)): return provisional.key == key
            default: return false
            }
        }
    }

    /// A create pressed on a pending create's stand-in (a split's, a New Terminal Tab's, Cmd-N's first pane): remember
    /// what made the stand-in, so the target stays found once the daemon's pane takes it over under a new handle.
    static func rememberStandInTarget(_ target: PaneID, in store: DaemonStore) {
        guard target.rawValue >= ProvisionalPane.firstHandle, store.standInTargets[target] == nil else { return }
        if let paneID = store.panesByHandle[target]?.resourceID?.rawValue {
            store.standInTargets[target] = .pane(paneID)
        } else if let origin = standInOrigin(of: target, in: store) {
            store.standInTargets[target] = origin
        }
    }

    /// The pane that shows `target` now: `target` itself, or the daemon's pane that took a stand-in target over.
    static func shownPane(_ target: PaneID, in store: DaemonStore) -> PaneID? { shownTarget(target, in: store) }

    /// The pane the overlay places beside: `target`, or the pane that shows a stand-in target now
    /// (the stand-in itself while it is pending, the daemon's pane once it took it over).
    private static func shownTarget(_ target: PaneID, in store: DaemonStore) -> PaneID? {
        if store.panesByHandle[target] != nil { return target }
        return daemonHandle(showing: target, in: store)
    }

    /// The daemon's pane under the split's public pane id, once its records hold it.
    static func daemonPane(_ provisional: ProvisionalPane, in store: DaemonStore) -> PaneModel? {
        store.index.panesByResource[ResourceID(rawValue: provisional.paneID)].flatMap { $0.handle != provisional.handle ? $0 : nil }
    }

    static func apply(target: PaneID, direction: SplitDirection, ratio: Double, provisional: ProvisionalPane,
                      to store: DaemonStore) -> IntentUndo? {
        let daemon = daemonPane(provisional, in: store)
        guard !daemonPlaces(provisional, in: store) else { return nil }
        let leaf = daemon?.handle ?? provisional.handle
        rememberStandInTarget(target, in: store)
        guard let target = shownTarget(target, in: store), store.panesByHandle[target] != nil,
              daemon != nil || (store.panesByHandle[provisional.handle] == nil && store.tabsBySurface[provisional.surface] == nil),
              let screen = store.screen(containing: target) else { return nil }
        if let column = provisional.column {
            return applyColumn(column, after: target, leaf: leaf, daemon: daemon, provisional: provisional, screen: screen, in: store)
        }
        if let row = provisional.row {
            return applyRow(row, below: target, leaf: leaf, daemon: daemon, provisional: provisional, screen: screen, in: store)
        }
        guard let layout = split(screen.layout, target, direction, ratio, leaf, provisional.splitID) else { return nil }
        // The target's column tree (and row tree) take the split too; a tree the split cannot
        // reach leaves the intent unapplied, as cmux-tui would refuse it.
        var reached = true
        let columns = screen.columns.map { column -> ColumnSnapshot in
            guard column.layout.paneIDs.contains(target) else { return column }
            var column = column
            guard let tree = split(column.layout, target, direction, ratio, leaf, provisional.splitID) else {
                reached = false
                return column
            }
            column.layout = tree
            column.rows = column.rows.map { row -> RowSnapshot in
                guard row.layout.paneIDs.contains(target) else { return row }
                var row = row
                guard let rowTree = split(row.layout, target, direction, ratio, leaf, provisional.splitID) else {
                    reached = false
                    return row
                }
                row.layout = rowTree
                return row
            }
            return column
        }
        guard reached else { return nil }
        // With the daemon's pane already listed, only the layout is the overlay's.
        let undo = IntentUndo.splitPane(screen: screen.handle, layout: screen.layout, columns: screen.columns,
                                        pane: daemon == nil ? provisional.handle : nil)
        screen.layout = layout
        if columns != screen.columns { screen.columns = columns }
        guard daemon == nil else { return undo }
        let pane = model(of: provisional, in: store)
        let after = (screen.panes.firstIndex { $0.handle == target } ?? screen.panes.count - 1) + 1
        screen.panes.insert(pane, at: min(after, screen.panes.count))
        store.index.insert(pane, in: screen)
        return undo
    }

    /// New Column's overlay (`new-pane-right`, cmux-tui `new_pane_right`): a column holding `leaf`
    /// right after the target's column (right before it for New Column Left, `side: "left"`), at
    /// the column's width. Every column there keeps its width (R3b). A screen that is still a
    /// split tree becomes two columns, the tree at full width and the new one, as the daemon wraps
    /// its root in a viewport split.
    private static func applyColumn(_ column: ProvisionalColumn, after target: PaneID, leaf: PaneID, daemon: PaneModel?,
                                    provisional: ProvisionalPane, screen: ScreenModel, in store: DaemonStore) -> IntentUndo? {
        var columns = screen.columns
        if columns.isEmpty {
            // A zoomed or docked screen has no tree column to open beside.
            guard screen.zoomedPane == nil else { return nil }
            columns = [ColumnSnapshot(id: column.treeHandle, width: 1, layout: screen.layout)]
        }
        // The target's column: its index places the new column, its panes place the new pane.
        guard let index = columns.firstIndex(where: { $0.layout.paneIDs.contains(target) }),
              let anchor = columns[checked: index]?.layout.paneIDs else { return nil }
        columns.insert(ColumnSnapshot(id: column.handle, width: column.width, layout: .leaf(leaf)), at: column.left ? index : index + 1)
        let undo = IntentUndo.splitPane(screen: screen.handle, layout: screen.layout, columns: screen.columns,
                                        pane: daemon == nil ? provisional.handle : nil)
        // The compat tree the daemon keeps beside its columns: the screen's tree with the new leaf on its side.
        screen.layout = column.left
            ? .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(leaf), b: screen.layout)
            : .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: screen.layout, b: .leaf(leaf))
        screen.columns = columns
        guard daemon == nil else { return undo }
        let pane = model(of: provisional, in: store)
        let at = column.left
            ? (screen.panes.firstIndex { anchor.contains($0.handle) } ?? 0)
            : (screen.panes.lastIndex { anchor.contains($0.handle) } ?? screen.panes.count - 1) + 1
        screen.panes.insert(pane, at: min(at, screen.panes.count))
        store.index.insert(pane, in: screen)
        return undo
    }

    /// New Row's overlay (`new-row`, cmux-tui `new_row_with_options_as`): a row holding `leaf` right
    /// below the target's row in its column, at the row's height. A screen that is still a split
    /// tree becomes one column, and a column without rows gets its tree as its first row (1000),
    /// as the daemon does. The column's `layout` stays the compat chain of its rows.
    private static func applyRow(_ row: ProvisionalRow, below target: PaneID, leaf: PaneID, daemon: PaneModel?,
                                 provisional: ProvisionalPane, screen: ScreenModel, in store: DaemonStore) -> IntentUndo? {
        guard screen.zoomedPane == nil else { return nil }
        var columns = screen.columns
        if columns.isEmpty { columns = [ColumnSnapshot(id: ColumnID(rawValue: row.firstHandle.rawValue | (1 << 60)), width: 1, layout: screen.layout)] }
        guard let index = columns.firstIndex(where: { $0.layout.paneIDs.contains(target) }),
              var column = columns[checked: index] else { return nil }
        var rows = column.rows.isEmpty ? [RowSnapshot(id: row.firstHandle, height: 1000, layout: column.layout)] : column.rows
        guard let at = rows.firstIndex(where: { $0.layout.paneIDs.contains(target) }) else { return nil }
        rows.insert(RowSnapshot(id: row.handle, height: row.height, layout: .leaf(leaf)), at: at + 1)
        column.rows = rows
        // The column's compat chain of its rows (rows holds at least the target's row and the new one).
        guard let first = rows.first else { return nil }
        column.layout = rows.dropFirst().reduce(first.layout) { chain, next in
            .split(id: nil, resourceID: nil, direction: .down, ratio: 0.5, a: chain, b: next.layout)
        }
        columns.replaceSubrange(index...index, with: [column])
        let undo = IntentUndo.splitPane(screen: screen.handle, layout: screen.layout, columns: screen.columns,
                                        pane: daemon == nil ? provisional.handle : nil)
        screen.layout = split(screen.layout, target, .down, 0.5, leaf, provisional.splitID)
            ?? .split(id: nil, resourceID: nil, direction: .down, ratio: 0.5, a: screen.layout, b: .leaf(leaf))
        screen.columns = columns
        guard daemon == nil else { return undo }
        let pane = model(of: provisional, in: store)
        let after = (screen.panes.firstIndex { $0.handle == target } ?? screen.panes.count - 1) + 1
        screen.panes.insert(pane, at: min(after, screen.panes.count))
        store.index.insert(pane, in: screen)
        return undo
    }

    /// The one model of `provisional` while its intent is pending: every restore shows the same
    /// object, and the daemon's pane-added takes it over (``DaemonStore/confirmedPane(_:)``).
    private static func model(of provisional: ProvisionalPane, in store: DaemonStore) -> PaneModel {
        if let model = store.provisionalPanes[provisional.paneID] { return model }
        let tab = provisional.tab ?? TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.tabID),
                                                 terminalID: TerminalID(rawValue: provisional.terminalID))
        let model = PaneModel(PaneSnapshot(id: provisional.handle, resourceID: ResourceID(rawValue: provisional.paneID),
                                           tabs: [tab]))
        store.provisionalPanes[provisional.paneID] = model
        return model
    }

    /// `pane`: the provisional pane to remove; nil when the split placed the daemon's pane.
    static func undo(screen handle: ScreenID, layout: LayoutNode, columns: [ColumnSnapshot], pane: PaneID?,
                     in store: DaemonStore) {
        guard let screen = store.screensByHandle[handle] else {
            return store.reportMirrorViolation("intent overlay undo found split screen \(handle) missing")
        }
        if let pane {
            guard let model = store.panesByHandle[pane] else {
                return store.reportMirrorViolation("intent overlay undo found provisional pane \(pane) missing")
            }
            store.index.remove(model)
            screen.panes.removeAll { $0 === model }
        }
        screen.layout = layout
        if screen.columns != columns { screen.columns = columns }
    }

    /// `node` with the leaf `target` replaced by a split of `target` and `new`, or nil when the
    /// leaf is not in it (or sits in a stack, which `split` turns into its own layout). The new
    /// split has no handle until the daemon's arrives; `splitID` is its public id.
    private static func split(_ node: LayoutNode, _ target: PaneID, _ direction: SplitDirection, _ ratio: Double,
                              _ new: PaneID, _ splitID: String) -> LayoutNode? {
        switch node {
        case .leaf(let pane) where pane == target:
            return .split(id: nil, resourceID: ResourceID(rawValue: splitID), direction: direction, ratio: ratio,
                          a: .leaf(target), b: .leaf(new))
        case .split(let id, let resourceID, let dir, let r, let a, let b):
            if let a = split(a, target, direction, ratio, new, splitID) {
                return .split(id: id, resourceID: resourceID, direction: dir, ratio: r, a: a, b: b)
            }
            if let b = split(b, target, direction, ratio, new, splitID) {
                return .split(id: id, resourceID: resourceID, direction: dir, ratio: r, a: a, b: b)
            }
            return nil
        default:
            return nil
        }
    }
}
