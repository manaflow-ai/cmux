import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

// A sidebar workspace dropped on a pane of the shown workspace (Leo
// 2026-10-06): its tabs come in the way a tab drag would bring one. The
// pane's center takes them as tabs at the end of its strip; an edge, a
// column gap or a dock band makes the new pane and the rest of the tabs
// join it. The emptied workspace closes (`finishClosing`).
/// A workspace merge, run for the drag session that dropped it.
enum WorkspaceMerge {
    /// Moves every tab of `workspaceID` to `kind` in `window`: the first
    /// tab with the tab drag's own command, then the others into the pane
    /// it landed in, in workspace order. The workspace closes once empty.
    static func run(_ workspaceID: String, at kind: TabDropKind, into window: WindowController, drag: TabDragSession.Drag,
                    session: TabDragSession) {
        let services = session.services
        guard let source = services.workspace(id: workspaceID), let outcome = outcome(kind) else { return }
        let tabs = source.screens.flatMap(\.panes).flatMap(\.tabs)
        guard let first = tabs.first, let daemon = services.machines.daemon(forWorkspace: workspaceID) else { return }
        session.claimClosing(source)
        let transaction = ClientTransactionID.generate()
        session.executeTab(outcome, tab: first, dropWindow: window, drag: drag, transaction: transaction) { [weak session] ok in
            guard let session else { return }
            guard ok else { return session.finishClosing(source, moved: false) }
            daemon.whenApplied(transaction) { [weak session] in
                moveRest(Array(tabs.dropFirst()), following: first.id, services: services) { moved in
                    session?.finishClosing(source, moved: moved)
                }
            }
        }
    }

    /// The pane target of `window`'s layout under `point` for a workspace
    /// drag that may merge there, and the layout adapter showing it.
    static func hit(_ point: CGPoint, ids: [String], group: String?, window: WindowController,
                    layout: LayoutTabDropTarget, services: AppServices) -> TabDropProposal? {
        guard let id = ids.first, allowed(ids, group: group, into: window, services: services),
              let proposal = layout.workspaceHitTest(screenPoint: point, workspaceID: id), outcome(proposal.kind) != nil else { return nil }
        return proposal
    }

    /// Whether `ids` may merge into `window`'s shown workspace: one
    /// workspace, not Home, not the shown one, on the same machine.
    static func allowed(_ ids: [String], group: String?, into window: WindowController, services: AppServices) -> Bool {
        guard group == nil, ids.count == 1, let id = ids.first, let source = services.workspace(id: id),
              !EmptyWorkspaceRepair.isHome(source), let shown = window.content?.workspace, shown.id != id else { return false }
        return services.machines.daemon(forWorkspace: id) === services.machines.daemon(forWorkspace: shown.id)
    }

    /// The tab move a merge drop on `kind` makes for the workspace's first
    /// tab; nil for targets a workspace never takes.
    static func outcome(_ kind: TabDropKind) -> TabDragOutcome? {
        switch kind {
        case .strip(let stripID, let index, _): .strip(stripID: stripID, index: index, groupID: nil)
        case .newSplit(let pane, let edge): .newSplit(paneID: pane, edge: edge)
        case .newColumn(let screen, let after?): .newColumn(screenID: screen, afterColumnID: after)
        case .newDock(let screen, let edge): .newDock(screenID: screen, edge: edge)
        case .newColumn(_, nil), .newWorkspace, .workspace: nil
        }
    }

    /// Moves `tabs` one at a time to the end of the pane holding `anchor`.
    static func moveRest(_ tabs: [TabModel], following anchor: String, services: AppServices,
                         completion: @escaping @MainActor (Bool) -> Void) {
        guard let tab = tabs.first else { return completion(true) }
        guard let (_, pane) = services.locateTab(anchor) else { return completion(false) }
        TabMoves.move(tab, to: pane, index: pane.tabs.count, services: services) { ok in
            guard ok else { return completion(false) }
            moveRest(Array(tabs.dropFirst()), following: anchor, services: services, completion: completion)
        }
    }
}
