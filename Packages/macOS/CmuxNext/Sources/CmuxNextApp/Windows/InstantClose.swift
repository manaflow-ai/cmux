import CmuxNextSidebar

/// Close Workspace at the press (Lawrence 2026-10-17: "this needs to be instant"; `ClosingWorkspaces` owns the state).
enum InstantClose {
    /// A close the person asked for (`ClosingWorkspaces`): `id` leaves its window `window` now, unless no other row of
    /// the room it shows would be left (then false). The selections move, and `window`'s sidebar (the row starts closing,
    /// the next row is selected) and content show it in this turn, not an observation hop later.
    static func begin(_ id: String, in window: String?, windows: WindowManager) -> Bool {
        guard let window, let controller = windows.controller(for: window) else { return false }
        let room = WindowProfiles.visible(windows.registry.members(of: window), profile: controller.state.profileID, machines: windows.services.machines)
        guard ClosingWorkspaces.shared.begin(id, among: room) else { return false }
        // Preserve the pre-close order. ClosingWorkspaces hides `id` before
        // repairSelections runs; reconstructing the old order afterward can
        // make a last-row close fall back to the first surviving workspace.
        windows.repairSelections(previous: [window: room])
        controller.sidebar.sameTurn.syncNow(rows: true)
        controller.showWorkspace(requested: controller.state.workspaceID)
        return true
    }
}
