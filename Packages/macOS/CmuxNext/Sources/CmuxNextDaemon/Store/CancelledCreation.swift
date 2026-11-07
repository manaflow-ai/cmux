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
        case .dockTab(_, _, _, _, let standIn): standIn?.surface
        default: nil
        }
    }

    /// Whether `transaction`'s creation goes on when its stand-in tab closes (a dock: the chat still docks; only its
    /// fresh tab is closed, ``closeStandIn(_:in:)``), rather than being cancelled whole.
    static func keepsCreation(_ transaction: ClientTransactionID, in store: DaemonStore) -> Bool {
        guard case .dockTab? = store.intentLog.entries.first(where: { $0.transaction == transaction })?.kind else { return false }
        return true
    }

    /// The person closed the stand-in tab of `transaction` while its creation goes on (Leo 2026-11-03: "i should be
    /// able to just close immedeiately"; #33829): the stand-in leaves the visible state now, and the daemon's fresh tab
    /// is hidden when it arrives and closed as soon as it is known (``requestCloses(in:)``), never shown.
    static func closeStandIn(_ transaction: ClientTransactionID, in store: DaemonStore) {
        guard store.intentLog.markStandInClosed(transaction) else { return }
        store.withOverlayLifted(writer: "stand-in closed") {}
        requestCloses(in: store)
    }

    /// The daemon's tab that replaces a closed stand-in, in the records: for a dock, the tab of its pane that runs
    /// the stand-in's terminal (the client minted that id, so no other tab has it).
    static func freshTab(of entry: PendingIntent, in store: DaemonStore) -> TabModel? {
        guard case .dockTab(_, let source, _, _, let standIn?) = entry.kind, let terminal = standIn.terminalID,
              let pane = store.panesByHandle[source] else { return nil }
        return pane.tabs.first { $0.terminalID == terminal && !ProvisionalTab.isProvisional(surface: $0.surface) }
    }

    /// The overlay of a creation whose stand-in was closed: the creation's own overlay without the stand-in, then
    /// the daemon's fresh tab taken out of the visible records once they hold it.
    static func restoreClosedStandIn(_ entry: PendingIntent, in store: DaemonStore) -> IntentUndo? {
        guard case .dockTab(let surface, let source, let provisional, let dock, _) = entry.kind else { return nil }
        let overlay = ProvisionalSplit.paneGone(entry, in: store) ? nil
            : ProvisionalDock.apply(surface: surface, from: source, provisional: provisional, dock: dock, standIn: nil, to: store)
        let hidden = freshTab(of: entry, in: store).flatMap { hideTab($0.surface, in: store) }
        guard overlay != nil || hidden != nil else { return nil }
        return .closedStandIn(overlay: overlay, hidden: hidden)
    }

    /// Whether the confirmed records still hold the daemon's fresh tab of a closed stand-in (its close not committed).
    static func freshTabHeld(_ entry: PendingIntent, in store: DaemonStore) -> Bool {
        if let fresh = freshTab(of: entry, in: store) { return store.tabsBySurface[fresh.surface] != nil }
        return false
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
        case .closedStandIn(_, let hidden)?: hidden?.tab.surface
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
            guard let pane = daemonPane(provisional, in: store), let hidden = hidePane(pane, in: store) else { return nil }
            return .hiddenPane(hidden)
        default:
            return nil
        }
    }

    /// The pane a ``Intent/closeStandInPane(pane:paneID:workspace:)`` takes out: the stand-in while it shows, else
    /// the daemon's pane that took it over.
    static func closingPane(_ intent: Intent, in store: DaemonStore) -> PaneModel? {
        guard case .closeStandInPane(let handle, let paneID, let workspace) = intent else { return nil }
        if let pane = store.panesByHandle[handle] { return pane }
        if let paneID, let pane = store.index.panesByResource[ResourceID(rawValue: paneID)], pane.handle != handle { return pane }
        if let workspace, let adopted = ProvisionalWorkspaceOverlay.adoptedPane(of: workspace, in: store) { return store.panesByHandle[adopted] }
        return nil
    }

    /// The daemon's pane that a pending close of stand-in `handle` hides, once the daemon made it.
    static func hiddenDaemonPane(closing handle: PaneID, in store: DaemonStore) -> PaneID? {
        for entry in store.intentLog.entries {
            guard case .closeStandInPane(let pane, _, _) = entry.kind, pane == handle,
                  case .hiddenPane(let hidden)? = entry.undo, hidden.pane.handle.rawValue < ProvisionalPane.firstHandle else { continue }
            return hidden.pane.handle
        }
        return nil
    }

    /// Takes `pane` out of the visible records with its screen's trees (its split collapses; a column or row that is
    /// only this pane goes with it). Nil when it is its tree's only pane (it would leave no pane): it stays shown.
    static func hidePane(_ pane: PaneModel, in store: DaemonStore) -> HiddenPane? {
        guard let screen = store.screen(containing: pane.handle),
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
        return HiddenPane(pane: pane, screen: screen.handle, index: index, layout: layout, columns: columns)
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
        case .hiddenPane(let hidden)?: hidden.pane.tabs.count { !ProvisionalTab.isProvisional(surface: $0.surface) }
        case .closedTabs(let hidden)?: hidden.count
        case .guessedTab?: 1
        case .closedStandIn(let overlay, let hidden)?: hiddenTabs(overlay) + (hidden == nil ? 0 : 1)
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
