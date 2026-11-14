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
extension DaemonStore {
    /// What one lift holds: each pending create's workspace (its screens) and the screen of each pending split, zoom or
    /// swap (its tree and its zoom).
    struct HeldOverlayPublication {
        var workspaces: [WorkspaceModel] = []
        var screens: [ScreenModel] = []
    }

    /// Holds the publication of the list, of each pending create's workspace's screens and of the tree and zoom of each
    /// pending split's, zoom's or swap's screen; returns what it held.
    func holdOverlayPublication() -> HeldOverlayPublication {
        if listBeforeLift == nil { listBeforeLift = workspaceList }
        var held = HeldOverlayPublication()
        for entry in intentLog.entries {
            if let handle = entry.undo?.heldScreen, let screen = screensByHandle[handle] {
                screen.holdTree()
                held.screens.append(screen)
            }
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
    /// publishes none.
    func publishOverlayNetChange(_ held: HeldOverlayPublication) {
        if let before = listBeforeLift {
            listBeforeLift = nil
            // The same storage: no lift or restore wrote the list (no pending intent moved a workspace), O(1).
            if !before.sharesStorage(with: workspaceList), !before.elementsEqual(workspaceList, by: ===) { workspaces = workspaceList }
        }
        for workspace in held.workspaces { workspace.publishHeldScreens() }
        for screen in held.screens { screen.publishHeldTree() }
    }
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
