import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTabs
import QuartzCore

// Outcome -> one daemon command, and the lookups it needs.
extension TabDragSession {
    // MARK: Commit

    /// Sends the one daemon command for `outcome`; its response settles the
    /// lifecycle (a rejection restores the source strip).
    func execute(_ outcome: TabDragOutcome, drag: Drag, transaction: ClientTransactionID) {
        let lifecycle = drag.lifecycle
        let emptied = emptiedSourceWorkspace(drag)
        // The tabs leave their workspace for another one: the emptied
        // workspace closes once they landed, and is never repaired meanwhile.
        emptied.map { claimClosing($0) }
        // A landed move settles once the store holds its result (its echo),
        // so ending the presentation shows the daemon's placement, never a
        // stale one.
        let daemon = drag.source.pane.map { services.machines.daemon(forPane: $0.pane) }
        let dropWindow = drag.winner?.window ?? drag.source.window
        commitsInFlight.insert(transaction)
        let settle: @MainActor (Bool) -> Void = { [weak self] ok in
            let end: @MainActor () -> Void = { [weak self] in
                lifecycle.settle(transaction, ok: ok)
                self?.commitsInFlight.remove(transaction)
                self?.services.inputMonitor.noteChange()
                // The view change of a landed user drop, after the echo.
                if ok { self?.revealLanded(drag, outcome: outcome, dropWindow: dropWindow) }
            }
            if ok, let daemon { daemon.whenApplied(transaction, end) } else { end() }
            if let emptied { self?.finishClosing(emptied, moved: ok) }
        }
        switch drag.source.item {
        case .tab(let id):
            guard let (tab, _) = services.locateTab(id) else {
                // A session-local tab (an agent pane) is not a daemon tab
                // and cannot move; say so instead of snapping back silently.
                if outcome != .cancel { services.registry.refuse(RefusalStrings.sessionLocalTab(id)) }
                return settle(false)
            }
            executeTab(outcome, tab: tab, dropWindow: dropWindow, drag: drag, transaction: transaction, settle: settle)
        case .group(let id, _):
            executeGroup(outcome, group: CmuxNextDaemon.TabGroupID(rawValue: id.rawValue), dropWindow: dropWindow, drag: drag,
                         transaction: transaction, settle: settle)
        case .workspaces:
            settle(false)
        }
    }

    func executeTab(_ outcome: TabDragOutcome, tab: TabModel, dropWindow: WindowController?, drag: Drag,
                            transaction: ClientTransactionID, settle: @escaping @MainActor (Bool) -> Void) {
        switch outcome {
        case .strip(let stripID, let index, let groupID):
            guard let pane = paneController(stripID: stripID) else { return settle(false) }
            TabMoves.move(tab, to: pane.pane, index: index, services: services, transaction: transaction) { [weak pane] ok in
                if ok {
                    pane?.syncGroupMembership(of: tab, to: groupID)
                } else {
                    pane?.resyncStrip()
                }
                settle(ok)
            }
        case .newSplit(let paneID, let edge):
            guard let pane = paneModel(id: paneID) else { return settle(false) }
            // The tab's own pane with its only tab: the owner spawns a fresh
            // tab of the same kind there in the same op.
            let respawn = liveContext(drag).splitRespawns(pane: paneID) ? TabMoves.respawn(for: tab, in: pane, services: services) : nil
            TabMoves.toNewSplit(tab, pane: pane, edge: edge.paneEdge, services: services, respawn: respawn, transaction: transaction,
                                completion: settle)
        case .newColumn(let screenID, let after):
            guard let (anchor, column) = columnAnchor(screenID: screenID, after: after, in: dropWindow) else { return settle(false) }
            TabMoves.toNewColumn(tab, anchor: anchor, afterColumn: column, services: services, transaction: transaction, completion: settle)
        case .newWorkspace:
            // Made unplaced, then put at the gap by the sidebar's own path
            // (personal order, or move-workspace-to-group at the slot).
            let slot = gapSlot(drag)
            Task {
                let key = await TabMoves.toNewWorkspace(tab, services: services, transaction: transaction)
                drag.landedWorkspaceID = key?.rawValue
                if let key, let state = dropWindow?.state { claimAndPlace(key, in: state, at: slot, select: !drag.filesAway) }
                settle(key != nil)
            }
        case .workspace(let id):
            guard let workspace = services.workspace(id: id) else { return settle(false) }
            drag.landedWorkspaceID = id
            TabMoves.toWorkspace(tab, workspace: workspace, services: services, transaction: transaction, completion: settle)
        case .tearOff(let point):
            let frame = tearOffFrame(drag, at: point, size: drag.source.windowSize)
            Task {
                let key = await TabMoves.toNewWorkspace(tab, services: services, transaction: transaction)
                drag.landedWorkspaceID = key?.rawValue
                if let key { focusTornOff(openTornOff(workspace: key, frame: frame, drag: drag), drag: drag) }
                settle(key != nil)
            }
        case .moveWindow, .moveWorkspaceToNewWindow, .moveWorkspace, .cancel:
            settle(false)
        }
    }

    func executeGroup(_ outcome: TabDragOutcome, group: CmuxNextDaemon.TabGroupID, dropWindow: WindowController?, drag: Drag,
                              transaction: ClientTransactionID, settle: @escaping @MainActor (Bool) -> Void) {
        switch outcome {
        case .strip(let stripID, let index, _):
            guard let pane = paneController(stripID: stripID) else { return settle(false) }
            TabGroupMoves.move(group, to: pane.pane, index: index, services: services, transaction: transaction) { [weak pane] ok in
                if !ok { pane?.resyncStrip() }
                settle(ok)
            }
        case .newSplit(let paneID, let edge):
            guard let pane = paneModel(id: paneID) else { return settle(false) }
            TabGroupMoves.toNewSplit(group, pane: pane, edge: edge.paneEdge, services: services, transaction: transaction, completion: settle)
        case .newColumn(let screenID, let after):
            guard let (anchor, column) = columnAnchor(screenID: screenID, after: after, in: dropWindow) else { return settle(false) }
            TabGroupMoves.toNewColumn(group, anchor: anchor, afterColumn: column, services: services, transaction: transaction,
                                      completion: settle)
        case .newWorkspace:
            let slot = gapSlot(drag)
            Task {
                let key = await TabGroupMoves.toNewWorkspace(group, workspaceGroup: nil, index: nil, services: services, transaction: transaction)
                drag.landedWorkspaceID = key?.rawValue
                if let key, let state = dropWindow?.state { claimAndPlace(key, in: state, at: slot, select: !drag.filesAway) }
                settle(key != nil)
            }
        case .workspace(let id):
            // Into the workspace's first pane, after its tabs.
            guard let pane = services.workspace(id: id)?.screens.first?.panes.first else { return settle(false) }
            drag.landedWorkspaceID = id
            TabGroupMoves.move(group, to: pane, index: pane.tabs.count, services: services, transaction: transaction, completion: settle)
        case .tearOff(let point):
            let frame = tearOffFrame(drag, at: point, size: drag.source.windowSize)
            Task {
                let key = await TabGroupMoves.toNewWorkspace(group, workspaceGroup: nil, index: nil, services: services, transaction: transaction)
                drag.landedWorkspaceID = key?.rawValue
                if let key { focusTornOff(openTornOff(workspace: key, frame: frame, drag: drag), drag: drag) }
                settle(key != nil)
            }
        case .moveWindow, .moveWorkspaceToNewWindow, .moveWorkspace, .cancel:
            settle(false)
        }
    }

    /// Opens the torn-off workspace in a new window under the pointer. The
    /// window list and frame persist through `WindowManager`.
    @discardableResult
    /// A tab torn off an incognito window opens an incognito window.
    func openTornOff(workspace key: WorkspaceKey, frame: CGRect, drag: Drag) -> WindowController? {
        let incognito = drag.source.window.map { services.windows.isIncognito(window: $0.state.id) } ?? false
        // Option files it away: the new window opens behind, never key.
        return services.windows.openWindow(workspaces: [key.rawValue], frame: frame, incognito: incognito, behind: drag.filesAway)
    }

    // MARK: Lookup

    /// The sidebar gap or collapsed group the drag was dropped on.
    func gapSlot(_ drag: Drag) -> WorkspaceSlot? {
        switch (drag.winner?.provider as? SidebarTabDropTarget)?.lastDrop {
        case .newWorkspace(let section, let group, let index)?: .at(DropPosition(section: section, group: group, index: index))
        case .intoGroup(let group)?: .endOfGroup(group)
        case .intoWorkspace?, nil: nil
        }
    }

    func claimAndPlace(_ key: WorkspaceKey, in state: WindowState, at slot: WorkspaceSlot?, select: Bool = true) {
        services.windows.claim(workspaceID: key.rawValue, in: state, select: select)
        if let slot { services.windows.place(newWorkspace: key.rawValue, in: state.id, at: slot) }
    }

    /// The view change after a landed drop (`DropRevealPolicy`): drags are
    /// always the user's; Option files the tabs away.
    func revealLanded(_ drag: Drag, outcome: TabDragOutcome, dropWindow: WindowController?) {
        // A move onto another machine is a reference move, not this
        // client's layout: no view change (product decision 2026-10-01).
        if let landed = drag.landedWorkspaceID, let source = drag.source.pane,
           services.machines.daemon(forWorkspace: landed) !== services.machines.daemon(forPane: source.pane) { return }
        let landing = drag.landedWorkspaceID.flatMap { services.windows.registry.value.owner(of: $0) }
            .flatMap(services.windows.controller(for:)) ?? dropWindow
        let facts = DropRevealPolicy.Facts(outcome: outcome, landed: true, userInitiated: true, filesAway: drag.filesAway,
                                           crossesWindows: landing !== drag.source.window, appActive: NSApp.isActive,
                                           noActivate: WindowPlacement.noActivate,
                                           landingOnActiveSpace: landing?.window?.isOnActiveSpace ?? true)
        guard let reveal = DropRevealPolicy.decide(facts) else { return }
        services.applyReveal(reveal, workspaceID: drag.landedWorkspaceID, fallback: dropWindow)
    }

    func paneController(stripID: UUID) -> PaneController? {
        for controller in services.windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] where pane.stripModel.stripID == stripID { return pane }
        }
        return nil
    }

    func paneModel(id: String) -> PaneModel? {
        for (workspace, _) in services.machines.allWorkspaces {
            for screen in workspace.screens {
                if let pane = screen.panes.first(where: { $0.id == id }) { return pane }
            }
        }
        return nil
    }

    /// The pane to anchor a new column on (the last pane of the column the
    /// new one follows) and that column's daemon id.
    func columnAnchor(screenID: String, after: String, in window: WindowController?) -> (PaneModel, DaemonColumnID?)? {
        guard let content = window?.content,
              let screen = content.layoutModel.screens.first(where: { $0.id.rawValue == screenID }),
              let column = screen.layout.columns.first(where: { $0.id.rawValue == after }),
              let anchor = column.root.panes.last, let handle = content.handles.panes[anchor],
              let pane = content.daemon.store.pane(handle) else { return nil }
        return (pane, content.handles.columns[column.id])
    }
}
