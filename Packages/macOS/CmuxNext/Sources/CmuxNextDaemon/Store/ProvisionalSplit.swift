import Foundation

/// The overlay of a split intent (`Intent.splitPane`, plans/cmux-next/remote-state-ownership.md
/// S3): the provisional pane is inserted after the target leaf, as `split` does in cmux-tui
/// (`split_kind.rs`, the target's column tree and the screen's tree), with one terminal tab under
/// the client-minted ids. Undone exactly; never applied once the daemon has a pane with the same
/// public id, so the two never show side by side. The daemon reports that pane (`pane-added`)
/// before the layout that places it (`layout-changed`): in between, the split places the
/// daemon's pane instead, so the screen never shows unsplit (cx-ry0y).
@MainActor struct ProvisionalSplit {
    /// Whether the daemon's records hold that pane and a screen's layout places it: the split
    /// has nothing left to show.
    static func daemonPlaces(_ provisional: ProvisionalPane, in store: DaemonStore) -> Bool {
        guard let pane = daemonPane(provisional, in: store) else { return false }
        return store.screensByHandle.values.contains { $0.layout.paneIDs.contains(pane.handle) }
    }

    private static func daemonPane(_ provisional: ProvisionalPane, in store: DaemonStore) -> PaneModel? {
        store.panesByHandle.values.first { $0.resourceID?.rawValue == provisional.paneID && $0.handle != provisional.handle }
    }

    static func apply(target: PaneID, direction: SplitDirection, ratio: Double, provisional: ProvisionalPane,
                      to store: DaemonStore) -> IntentUndo? {
        let daemon = daemonPane(provisional, in: store)
        guard !daemonPlaces(provisional, in: store) else { return nil }
        let leaf = daemon?.handle ?? provisional.handle
        guard store.panesByHandle[target] != nil,
              daemon != nil || (store.panesByHandle[provisional.handle] == nil && store.tabsBySurface[provisional.surface] == nil),
              let screen = store.screensByHandle.values.first(where: { $0.pane(target) != nil }),
              let layout = split(screen.layout, target, direction, ratio, leaf) else { return nil }
        // The target's column tree (and row tree) take the split too; a tree the split cannot
        // reach leaves the intent unapplied, as cmux-tui would refuse it.
        var reached = true
        let columns = screen.columns.map { column -> ColumnSnapshot in
            guard column.layout.paneIDs.contains(target) else { return column }
            var column = column
            guard let tree = split(column.layout, target, direction, ratio, leaf) else {
                reached = false
                return column
            }
            column.layout = tree
            column.rows = column.rows.map { row -> RowSnapshot in
                guard row.layout.paneIDs.contains(target) else { return row }
                var row = row
                guard let rowTree = split(row.layout, target, direction, ratio, leaf) else {
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
        let tab = TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.tabID),
                              terminalID: TerminalID(rawValue: provisional.terminalID))
        let pane = PaneModel(PaneSnapshot(id: provisional.handle, resourceID: ResourceID(rawValue: provisional.paneID),
                                          tabs: [tab]))
        let after = (screen.panes.firstIndex { $0.handle == target } ?? screen.panes.count - 1) + 1
        screen.panes.insert(pane, at: min(after, screen.panes.count))
        store.panesByHandle[pane.handle] = pane
        for model in pane.tabs { store.tabsBySurface[model.surface] = model }
        return undo
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
            for tab in model.tabs { store.tabsBySurface[tab.surface] = nil }
            store.panesByHandle[pane] = nil
            screen.panes.removeAll { $0.handle == pane }
        }
        screen.layout = layout
        if screen.columns != columns { screen.columns = columns }
    }

    /// `node` with the leaf `target` replaced by a split of `target` and `new`, or nil when the
    /// leaf is not in it (or sits in a stack, which `split` turns into its own layout).
    private static func split(_ node: LayoutNode, _ target: PaneID, _ direction: SplitDirection, _ ratio: Double,
                              _ new: PaneID) -> LayoutNode? {
        switch node {
        case .leaf(let pane) where pane == target:
            return .split(id: nil, direction: direction, ratio: ratio, a: .leaf(target), b: .leaf(new))
        case .split(let id, let dir, let r, let a, let b):
            if let a = split(a, target, direction, ratio, new) { return .split(id: id, direction: dir, ratio: r, a: a, b: b) }
            if let b = split(b, target, direction, ratio, new) { return .split(id: id, direction: dir, ratio: r, a: a, b: b) }
            return nil
        default:
            return nil
        }
    }
}
