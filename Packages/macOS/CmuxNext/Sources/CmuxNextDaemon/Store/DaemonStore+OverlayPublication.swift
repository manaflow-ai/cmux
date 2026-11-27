import Foundation

/// The records the intent overlay takes out and puts back around every daemon apply publish only their net change,
/// once per apply (CLAUDE.md: a burst coalesces to one model update). A pending Cmd-N's stand-in left `workspaces`
/// and its screen left the stand-in's `screens` on each lift and came back on each restore: four writes per daemon
/// batch that cancelled every tracked reader of them (the sidebar's rows pass, window membership) while nothing a
/// person sees changed (SIDEBAR ROWS STATUS 15571 cause c: 15.6 ms of cancels and 19.0 ms of willSet per Cmd-N at
/// 200 rows). Held writes still change the records at once, so the apply reads the confirmed state; only the
/// observers wait for the lift's end, in the same turn.
///
/// A pending split (Cmd-D, New Column, New Row) did the same to its screen: the lift took the provisional pane out of
/// the screen's tree and the restore put it back, writing `layout`, `columns` and `panes` twice per daemon batch, so
/// every tracked reader of the shown workspace's tree (its content's layout mapping and every pane controller's strip,
/// which reads the screen's columns) mapped again on each batch, whatever workspace the batch was about: the busy
/// terminals of 30 background workspaces kept the shown workspace re-mapping through the split's own frames
/// (instant-splits, "off-screen work is deferred"). Its screen's tree is held the same way.
///
/// A pending tab creation (a New Tab key whose answer waits) did the same to its pane: the
/// lift took the stand-in tab out of the pane's tab list and the restore put a new record of it back, so each daemon
/// batch wrote the list 2 times for each creation that waited and every tracked reader of the list (the pane's strip)
/// mapped again, whatever workspace the batch was about. The pane's tab list is held the same way, the list's own
/// work (the unread count, the first tab, the group spans) runs one time at the hold's end, and the restore puts back
/// the record that the lift took out.
extension DaemonStore {
    /// Holds the publication of the list, of each pending create's workspace's screens, of the tree and zoom of each
    /// pending split's, zoom's or swap's screen and of the tab list of each pending tab creation's pane; returns what
    /// it held.
    func holdOverlayPublication() -> HeldOverlayPublication {
        if listBeforeLift == nil { listBeforeLift = workspaceList }
        var held = HeldOverlayPublication()
        for entry in intentLog.entries {
            if let handle = entry.undo?.heldScreen, let screen = screensByHandle[handle] {
                screen.holdTree()
                held.screens.append(screen)
            }
            if let handle = entry.undo?.standInPane, let pane = panesByHandle[handle], pane.holdTabs() { held.panes.append(pane) }
            guard case .createWorkspace(let provisional, _) = entry.kind, let workspace = createdWorkspace(provisional.key) else { continue }
            workspace.holdScreens()
            held.workspaces.append(workspace)
        }
        return held
    }

    /// The model a pending create shows: the daemon's workspace once it took the stand-in over, else the stand-in.
    private func createdWorkspace(_ key: WorkspaceKey) -> WorkspaceModel? {
        if let confirmed = workspacesByKey[key] { return confirmed }
        if let standIn = provisionalWorkspaces.workspacesByID[key.rawValue] { return standIn }
        return nil
    }

    /// Publishes what the lift changed: the list when it is not the same workspaces in the same order, and each held
    /// workspace's screens likewise. O(1) when nothing wrote the list, else O(list) pointer compares; no observer woken
    /// for a round trip. Each held screen's tree likewise, by value (panes by identity): a batch about another workspace
    /// publishes none. Each held pane's tab list likewise, by identity, with the list's own work after it.
    func publishOverlayNetChange(_ held: HeldOverlayPublication) {
        if let before = listBeforeLift {
            listBeforeLift = nil
            // The same storage: no lift or restore wrote the list (no pending intent moved a workspace), O(1).
            // The unread counts take in only what the lift changed (`adoptUnread(from:)`, from the list before it).
            if !before.sharesStorage(with: workspaceList), !before.elementsEqual(workspaceList, by: ===) {
                withMutation(keyPath: \.workspaces) {}
                adoptUnread(from: before)
            }
        }
        for workspace in held.workspaces { workspace.publishHeldScreens() }
        for screen in held.screens { screen.publishHeldTree() }
        for pane in held.panes { pane.publishHeldTabs() }
    }
}

/// What one lift holds: each pending create's workspace (its screens), the screen of each pending split, zoom or
/// swap (its tree and its zoom) and the pane of each pending tab creation (its tab list).
struct HeldOverlayPublication {
    var workspaces: [WorkspaceModel] = []
    var screens: [ScreenModel] = []
    var panes: [PaneModel] = []
}

extension IntentUndo {
    /// The screen whose tree a pending split's overlay changed (``ProvisionalSplit``), also inside a creation whose
    /// stand-in was closed or whose tab was guessed; nil for any other undo.
    var splitScreen: ScreenID? {
        switch self {
        case .splitPane(let screen, _, _, _): screen
        case .closedStandIn(let overlay, _): overlay?.splitScreen
        case .guessedTab(_, let provisional): provisional?.splitScreen
        default: nil
        }
    }

    /// The pane whose tab list holds a pending tab creation's stand-in tab, also inside a creation whose stand-in was
    /// closed or whose tab was guessed; nil for any other undo.
    var standInPane: PaneID? {
        switch self {
        case .createdTab(_, let pane): pane
        case .closedStandIn(let overlay, _): overlay?.standInPane
        case .guessedTab(_, let provisional): provisional?.standInPane
        default: nil
        }
    }

    /// The screen whose tree or zoom this undo's overlay changed: a pending split's, zoom's or swap's. The lift takes the
    /// change out and the restore puts it back, so the screen publishes only the net change of a daemon apply: the
    /// daemon's `layout-changed` for a zoom or a swap the screen already shows wakes no reader (no second layout).
    var heldScreen: ScreenID? {
        switch self {
        case .screenZoom(let screen, _), .swappedPanes(let screen, _, _): screen
        default: splitScreen
        }
    }
}
