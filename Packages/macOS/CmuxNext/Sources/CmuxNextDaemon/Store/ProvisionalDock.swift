import Foundation

/// The overlay of a lone tab docked into a new column under a client-minted pane id
/// (`Intent.dockTab`, `move-tab-to-column {dock, respawn, pane_id}`, `tab-column-client-pane-v1`):
/// in the key's turn the tab moves into the provisional pane, which leads the screen's columns as
/// the dock (cmux-tui's `commit_tab_drag` puts a left dock first), and the pane it left shows the
/// stand-in of its fresh tab until the daemon's fresh tab arrives. Undone exactly; never applied
/// once the daemon's layout places the pane with the same public id. Between that pane's
/// `pane-added` and the layout that places it, the dock places the daemon's pane, as a split does
/// (``ProvisionalSplit``), and the daemon's pane-added takes the provisional model over in place
/// (``DaemonStore/confirmedPane(_:)``).
@MainActor enum ProvisionalDock {
    /// What one apply changed, so its undo restores exactly that.
    struct Undo: Equatable {
        let screen: ScreenID
        let layout: LayoutNode
        let columns: [ColumnSnapshot]
        /// The provisional pane inserted; nil when the dock placed the daemon's pane.
        let pane: PaneID?
        let surface: SurfaceID
        let source: PaneID
        /// The pane the tab was moved into, and its index in `source` before; nil when the
        /// records already had it out of `source`.
        var moved: (holder: PaneID, index: Int)?
        /// The stand-in tab shown in `source`.
        var standIn: SurfaceID?

        static func == (lhs: Undo, rhs: Undo) -> Bool {
            lhs.screen == rhs.screen && lhs.layout == rhs.layout && lhs.columns == rhs.columns && lhs.pane == rhs.pane
                && lhs.surface == rhs.surface && lhs.source == rhs.source && lhs.moved?.holder == rhs.moved?.holder
                && lhs.moved?.index == rhs.moved?.index && lhs.standIn == rhs.standIn
        }
    }

    static func apply(surface: SurfaceID, from source: PaneID, provisional: ProvisionalPane, dock: DockSnapshot,
                      standIn: TabSnapshot?, to store: DaemonStore) -> IntentUndo? {
        guard let column = provisional.column, !ProvisionalSplit.daemonPlaces(provisional, in: store) else { return nil }
        let daemon = ProvisionalSplit.daemonPane(provisional, in: store)
        // A screen that already has a dock on that edge, or a zoomed one, waits for the daemon's
        // layout: `reduce_column_dock` there moves the old holder, which this overlay does not show.
        guard let pane = store.panesByHandle[source], let screen = store.screen(containing: source), screen.zoomedPane == nil,
              !screen.columns.contains(where: { $0.dock?.edge == dock.edge }),
              daemon != nil || !store.panesByHandle.keys.contains(provisional.handle) else { return nil }
        let from = pane.tabs.firstIndex { $0.surface == surface }
        guard from != nil || daemon?.tabs.contains(where: { $0.surface == surface }) == true else { return nil }
        let leaf = daemon?.handle ?? provisional.handle
        var columns = screen.columns
        if columns.isEmpty { columns = [ColumnSnapshot(id: column.treeHandle, width: 1, layout: screen.layout)] }
        columns.insert(ColumnSnapshot(id: column.handle, width: column.width, layout: .leaf(leaf), dock: dock), at: 0)
        var undo = Undo(screen: screen.handle, layout: screen.layout, columns: screen.columns,
                        pane: daemon == nil ? provisional.handle : nil, surface: surface, source: source)
        // The compat tree the daemon keeps beside its columns: the new leaf on the left.
        screen.layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(leaf), b: screen.layout)
        screen.columns = columns
        let holder: PaneModel
        if let daemon {
            holder = daemon
        } else {
            holder = model(of: provisional, in: store)
            screen.panes.insert(holder, at: 0)
            store.index.insert(holder, in: screen)
        }
        if let from, let tab = pane.removeTab(surface: surface) {
            holder.insertTab(tab, at: 0)
            store.index.insert(tab, in: holder)
            store.index.noteTabOrderChanged()
            undo.moved = (holder.handle, from)
        }
        // The fresh tab's stand-in, only while the daemon's fresh tab is not there yet.
        if pane.tabs.isEmpty, let standIn, !store.tabsBySurface.keys.contains(standIn.surface) {
            let tab = TabModel(standIn)
            pane.insertTab(tab, at: 0)
            store.index.insert(tab, in: pane)
            undo.standIn = standIn.surface
        }
        return .dockTab(undo)
    }

    static func undo(_ undo: Undo, in store: DaemonStore) {
        guard let screen = store.screensByHandle[undo.screen], let source = store.panesByHandle[undo.source] else {
            return store.reportMirrorViolation("intent overlay undo found dock screen \(undo.screen) or pane \(undo.source) missing")
        }
        if let standIn = undo.standIn {
            guard let tab = source.removeTab(surface: standIn) else {
                return store.reportMirrorViolation("intent overlay undo found stand-in \(standIn) missing from pane \(undo.source)")
            }
            store.index.remove(tab)
        }
        if let moved = undo.moved {
            guard let tab = store.panesByHandle[moved.holder]?.removeTab(surface: undo.surface) else {
                return store.reportMirrorViolation("intent overlay undo found docked surface \(undo.surface) missing from pane \(moved.holder)")
            }
            source.insertTab(tab, at: moved.index)
            store.index.insert(tab, in: source)
            store.index.noteTabOrderChanged()
        }
        if let pane = undo.pane {
            guard let model = store.panesByHandle[pane] else {
                return store.reportMirrorViolation("intent overlay undo found provisional dock pane \(pane) missing")
            }
            store.index.remove(model)
            screen.panes.removeAll { $0 === model }
        }
        screen.layout = undo.layout
        if screen.columns != undo.columns { screen.columns = undo.columns }
    }

    /// The one model of the dock's pane while its intent is pending (it holds no tab of its own:
    /// the docked tab moves in): every restore shows the same object.
    private static func model(of provisional: ProvisionalPane, in store: DaemonStore) -> PaneModel {
        if let model = store.provisionalPanes[provisional.paneID] { return model }
        let model = PaneModel(PaneSnapshot(id: provisional.handle, resourceID: ResourceID(rawValue: provisional.paneID), tabs: []))
        store.provisionalPanes[provisional.paneID] = model
        return model
    }
}
