import Foundation

/// A tab or pane the person closed while the daemon was still creating it ("Close before create",
/// .cmux-scratch/motion-redesign/DESIGN.md 2026-10-18). A close always wins, at once: its create
/// or split intent stays in the log marked `closeWhenCreated` and from then on shows nothing. The
/// daemon's tab or pane, when it arrives, is hidden by the same intent (never shown, in no window
/// and no sidebar), its surface is handed to ``DaemonCreations/onClose(_:)`` once known
/// (the reply, the echo, or the record), and the intent leaves the log only when the confirmed
/// records no longer hold it (that close committed) or the creation failed.
@MainActor enum CancelledCreation {
    /// The pending create or split intent that shows provisional tab `id`, while the tab shown under
    /// that id is still the provisional one (not the daemon's, which closes like any tab).
    static func transaction(showingTab id: String, in store: DaemonStore) -> ClientTransactionID? {
        guard let tab = store.index.tabsByID[id], ProvisionalTab.isProvisional(surface: tab.surface) else { return nil }
        return store.intentLog.entries.first { provisionalSurface(of: $0.kind) == tab.surface }?.transaction
    }

    /// The pending split intent whose provisional pane is `handle`.
    static func transaction(showingPane handle: PaneID, in store: DaemonStore) -> ClientTransactionID? {
        store.intentLog.entries.first { entry in
            guard case .splitPane(_, _, _, let provisional) = entry.kind else { return false }
            return provisional.handle == handle
        }?.transaction
    }

    private static func provisionalSurface(of intent: Intent) -> SurfaceID? {
        switch intent {
        case .createTab(_, let provisional): provisional.surface
        case .splitPane(_, _, _, let provisional): provisional.surface
        default: nil
        }
    }

    /// Whether the confirmed records hold what the cancelled creation made (the overlay is lifted).
    static func daemonHolds(_ entry: PendingIntent, in store: DaemonStore) -> Bool {
        if let surface = entry.createdSurface ?? entry.replySurface, store.tabsBySurface[surface] != nil { return true }
        guard case .splitPane(_, _, _, let provisional) = entry.kind else { return false }
        return daemonPane(provisional, in: store) != nil
    }

    /// The daemon's surface to close, once known.
    static func closeSurface(_ entry: PendingIntent) -> SurfaceID? {
        switch entry.undo {
        case .hiddenTab(let hidden)?: hidden.tab.surface
        case .hiddenPane(let hidden)?: hidden.pane.tabs.first?.surface ?? entry.createdSurface ?? entry.replySurface
        default: entry.createdSurface ?? entry.replySurface
        }
    }

    private static func daemonPane(_ provisional: ProvisionalPane, in store: DaemonStore) -> PaneModel? {
        store.index.panesByResource[ResourceID(rawValue: provisional.paneID)].flatMap { $0.handle != provisional.handle ? $0 : nil }
    }

    /// The overlay of a cancelled creation: the daemon's tab or pane, when the records hold it, is
    /// taken out of the visible records (undone exactly); before that, nothing.
    static func hide(_ entry: PendingIntent, in store: DaemonStore) -> IntentUndo? {
        switch entry.kind {
        case .createTab:
            guard let surface = entry.createdSurface ?? entry.replySurface, let hidden = hideTab(surface, in: store) else { return nil }
            return .hiddenTab(hidden)
        case .splitPane(_, _, _, let provisional):
            guard let pane = daemonPane(provisional, in: store), let screen = store.screen(containing: pane.handle),
                  let index = screen.panes.firstIndex(where: { $0 === pane }) else { return nil }
            let layout = screen.layout, columns = screen.columns
            // A tree the pane is the whole of (it would leave no pane) keeps it shown until the close.
            guard let unsplit = removing(pane.handle, from: layout) else { return nil }
            var reached = true
            // A column that is only this pane (New Column's) goes with it.
            let unsplitColumns = columns.filter { $0.layout != .leaf(pane.handle) }.map { column -> ColumnSnapshot in
                guard column.layout.paneIDs.contains(pane.handle) else { return column }
                var column = column
                guard let tree = removing(pane.handle, from: column.layout) else { reached = false; return column }
                column.layout = tree
                // A row that is only this pane (New Row's) goes with it.
                column.rows = column.rows.filter { $0.layout != .leaf(pane.handle) }.map { row in
                    guard row.layout.paneIDs.contains(pane.handle) else { return row }
                    var row = row
                    if let tree = removing(pane.handle, from: row.layout) { row.layout = tree } else { reached = false }
                    return row
                }
                return column
            }
            guard reached else { return nil }
            store.index.remove(pane)
            screen.panes.remove(at: index)
            screen.layout = unsplit
            if unsplitColumns != columns { screen.columns = unsplitColumns }
            return .hiddenPane(HiddenPane(pane: pane, screen: screen.handle, index: index, layout: layout, columns: columns))
        default:
            return nil
        }
    }

    /// Takes the daemon's tab on `surface` out of the visible records, with its place.
    static func hideTab(_ surface: SurfaceID, in store: DaemonStore) -> HiddenTab? {
        guard let tab = store.tabsBySurface[surface], let pane = store.index.pane(holding: tab),
              let index = pane.tabs.firstIndex(where: { $0 === tab }), let removed = pane.removeTab(surface: surface) else { return nil }
        store.index.remove(removed)
        store.index.noteTabOrderChanged()
        return HiddenTab(tab: removed, pane: pane.handle, index: index)
    }

    static func unhide(_ undo: IntentUndo, in store: DaemonStore) {
        switch undo {
        case .hiddenTab(let hidden):
            guard let pane = store.panesByHandle[hidden.pane] else {
                return store.reportMirrorViolation("cancelled creation undo found pane \(hidden.pane) missing")
            }
            pane.insertTab(hidden.tab, at: hidden.index)
            store.index.insert(hidden.tab, in: pane)
            store.index.noteTabOrderChanged()
        case .hiddenPane(let hidden):
            guard let screen = store.screensByHandle[hidden.screen] else {
                return store.reportMirrorViolation("cancelled creation undo found screen \(hidden.screen) missing")
            }
            screen.panes.insert(hidden.pane, at: min(hidden.index, screen.panes.count))
            store.index.insert(hidden.pane, in: screen)
            screen.layout = hidden.layout
            if screen.columns != hidden.columns { screen.columns = hidden.columns }
        default:
            break
        }
    }

    /// Tabs the cancelled creations' and closes' overlays took out of the visible records (the conservation check).
    static func hiddenTabs(in log: IntentLog) -> Int { log.entries.reduce(0) { $0 + hiddenTabs($1.undo) } }

    private static func hiddenTabs(_ undo: IntentUndo?) -> Int {
        switch undo {
        case .hiddenTab?: 1
        case .hiddenPane(let hidden)?: hidden.pane.tabs.count
        case .closedTabs(let hidden)?: hidden.count
        case .guessedTab?: 1
        default: 0
        }
    }

    /// `node` without leaf `pane` (its split collapses to the other side); nil when `node` is that leaf.
    static func removing(_ pane: PaneID, from node: LayoutNode) -> LayoutNode? {
        switch node {
        case .leaf(let leaf):
            return leaf == pane ? nil : node
        case .split(let id, let resourceID, let direction, let ratio, let a, let b):
            guard let a2 = removing(pane, from: a) else { return b }
            guard let b2 = removing(pane, from: b) else { return a2 }
            return .split(id: id, resourceID: resourceID, direction: direction, ratio: ratio, a: a2, b: b2)
        case .stack(let panes, let expanded):
            let rest = panes.filter { $0 != pane }
            guard let first = rest.first else { return nil }
            return .stack(panes: rest, expanded: expanded == pane ? first : expanded)
        case .unknown:
            return node
        }
    }
}

/// The daemon's tab a cancelled create intent hides, with its place.
struct HiddenTab: Equatable {
    let tab: TabModel
    let pane: PaneID
    let index: Int

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.tab === rhs.tab && lhs.pane == rhs.pane && lhs.index == rhs.index }
}

/// The daemon's pane a cancelled split intent hides, with the screen's trees it was in.
struct HiddenPane: Equatable {
    let pane: PaneModel
    let screen: ScreenID
    let index: Int
    let layout: LayoutNode
    let columns: [ColumnSnapshot]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pane === rhs.pane && lhs.screen == rhs.screen && lhs.index == rhs.index && lhs.layout == rhs.layout && lhs.columns == rhs.columns
    }
}
