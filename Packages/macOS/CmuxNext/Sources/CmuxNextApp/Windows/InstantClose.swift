import CmuxNextSidebar

/// Close Workspace at the press (Lawrence 2026-10-17: "this needs to be instant"; `ClosingWorkspaces` owns the state).
enum InstantClose {
    /// A close the person asked for (`ClosingWorkspaces`): `ids` (one row, or a selection's, `WorkspaceSelectionClose`)
    /// leave their window `window` now, in one sidebar pass, except a row whose leaving would leave no other row of the
    /// room it shows (a window closes with its last workspace, never empty). Returns the ids that left. The selections
    /// move, and `window`'s sidebar (the rows start closing, the next row is selected) and content show it in this turn,
    /// not an observation hop later.
    static func begin(_ ids: [String], in window: String?, windows: WindowManager) -> [String] {
        guard let window, let controller = windows.controller(for: window) else { return [] }
        let room = WindowProfiles.visible(windows.registry.members(of: window), profile: controller.state.profileID, machines: windows.services.machines)
        let hidden = ids.filter { ClosingWorkspaces.shared.begin($0, among: room) }
        guard !hidden.isEmpty else { return [] }
        // Preserve the pre-close order. ClosingWorkspaces hides the rows before
        // repairSelections runs; reconstructing the old order afterward can
        // make a last-row close fall back to the first surviving workspace.
        windows.repairSelections(previous: [window: room])
        controller.sidebar.sameTurn.syncNow(rows: true)
        controller.showWorkspace(requested: controller.state.workspaceID)
        return hidden
    }
}
