import Foundation

/// The records the intent overlay takes out and puts back around every daemon apply publish only their net change,
/// once per apply (CLAUDE.md: a burst coalesces to one model update). A pending Cmd-N's stand-in left `workspaces`
/// and its screen left the stand-in's `screens` on each lift and came back on each restore: four writes per daemon
/// batch that cancelled every tracked reader of them (the sidebar's rows pass, window membership) while nothing a
/// person sees changed (SIDEBAR ROWS STATUS 15571 cause c: 15.6 ms of cancels and 19.0 ms of willSet per Cmd-N at
/// 200 rows). Held writes still change the records at once, so the apply reads the confirmed state; only the
/// observers wait for the lift's end, in the same turn.
extension DaemonStore {
    /// Holds the publication of the list and of each pending create's workspace's screens; returns the held workspaces.
    func holdOverlayPublication() -> [WorkspaceModel] {
        if listBeforeLift == nil { listBeforeLift = workspaceList }
        var held: [WorkspaceModel] = []
        for entry in intentLog.entries {
            guard case .createWorkspace(let provisional, _) = entry.kind, let workspace = createdWorkspace(provisional.key) else { continue }
            workspace.holdScreens()
            held.append(workspace)
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
    /// workspace's screens likewise. O(list) pointer compares, no observer woken for a round trip.
    func publishOverlayNetChange(_ held: [WorkspaceModel]) {
        if let before = listBeforeLift {
            listBeforeLift = nil
            if !before.elementsEqual(workspaceList, by: ===) { workspaces = workspaceList }
        }
        for workspace in held { workspace.publishHeldScreens() }
    }
}
