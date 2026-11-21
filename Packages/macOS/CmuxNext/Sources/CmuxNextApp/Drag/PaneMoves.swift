import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextTabs
import Foundation

/// Whole-pane move commits (RFD 0022 item 2): a pane dragged by its header lands on every target a tab can
/// (a split on a pane's edge, a new column, an edge dock) by the tab drag's own commits. The pane's first tab
/// takes the move (it makes the destination pane), and the rest follow it there in order, so the surfaces are
/// reparented and never recreated. A single-tab pane (the common case) is one daemon command.
@MainActor
enum PaneMoves {
    typealias Completion = @MainActor (Bool) -> Void

    /// Moves every tab of `controller`'s pane to `target`, the drop a tab drag's preview showed (`updateTabDrag` with the
    /// pane as the one the drag empties). A target on the pane itself, or one that cannot take the move, is refused.
    static func move(_ controller: PaneController, to target: DropTarget, completion: @escaping Completion = { _ in }) {
        let services = controller.services, source = controller.pane
        guard let lead = source.tabs.first, let content = controller.workspace else { return completion(false) }
        let rest = Array(source.tabs.dropFirst())
        let landed: Completion = { ok in
            guard ok, !rest.isEmpty else { return completion(ok) }
            guard let home = services.locateTab(model: lead)?.1 else { return completion(false) }
            follow(rest[...], into: home, services: services, completion: completion)
        }
        switch target {
        case .pane(let id, let zone):
            guard let edge = zone.edge?.paneEdge, let pane = pane(id, in: content), pane !== source else { return completion(false) }
            TabMoves.toNewSplit(lead, pane: pane, edge: edge, services: services, roomDecided: true, completion: landed)
        case .newColumn(let screenID, let after):
            guard let after, let (anchor, column) = columnAnchor(screenID, after: after, avoiding: source, in: content) else { return completion(false) }
            TabMoves.toNewColumn(lead, anchor: anchor, afterColumn: column, services: services, completion: landed)
        case .newDock(let screenID, let edge):
            guard let anchor = screenAnchor(screenID, avoiding: source, in: content) else { return completion(false) }
            TabMoves.toNewDockColumn(lead, anchor: anchor, edge: edge, services: services, completion: landed)
        }
    }

    /// The remaining tabs, one after another, to the end of `home` (a move whose reply has not come has not moved the next tab's
    /// pane yet). A failed one stops the chain: what moved stays, and the failure is the move's.
    private static func follow(_ tabs: ArraySlice<TabModel>, into home: PaneModel, services: AppServices, completion: @escaping Completion) {
        guard let tab = tabs.first else { return completion(true) }
        TabMoves.move(tab, to: home, index: home.tabs.count, services: services) { ok in
            guard ok else { return completion(false) }
            follow(tabs.dropFirst(), into: home, services: services, completion: completion)
        }
    }

    private static func pane(_ id: PaneID, in content: WorkspaceContentController) -> PaneModel? {
        content.handles.panes[id].flatMap { content.daemon.store.pane($0) }
    }

    /// A pane of the screen that is not the one the move empties (the daemon refuses a pane's only tab leaving through itself).
    private static func screenAnchor(_ screenID: ScreenID, avoiding source: PaneModel, in content: WorkspaceContentController) -> PaneModel? {
        guard let screen = content.layoutModel.screens.first(where: { $0.id == screenID }) else { return nil }
        return screen.layout.panes.lazy.compactMap { pane($0, in: content) }.first { $0 !== source }
    }

    /// The pane to anchor a new column on (the last pane of the column the new one follows, else any other) and that column's daemon id.
    private static func columnAnchor(_ screenID: ScreenID, after: ColumnID, avoiding source: PaneModel,
                                     in content: WorkspaceContentController) -> (PaneModel, DaemonColumnID?)? {
        guard let screen = content.layoutModel.screens.first(where: { $0.id == screenID }),
              let column = screen.layout.columns.first(where: { $0.id == after }),
              let anchor = column.root.panes.reversed().lazy.compactMap({ pane($0, in: content) }).first(where: { $0 !== source })
                  ?? screenAnchor(screenID, avoiding: source, in: content) else { return nil }
        return (anchor, content.handles.columns[column.id])
    }
}
