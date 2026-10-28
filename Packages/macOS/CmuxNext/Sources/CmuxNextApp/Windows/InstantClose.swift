import CmuxNextSidebar

/// Close Workspace at the press (Lawrence 2026-10-17: "this needs to be instant"; `ClosingWorkspaces` owns the state).
enum InstantClose {
    /// A close the person asked for (`ClosingWorkspaces`): `id` leaves its window `window` now, unless no other row of
    /// the room it shows would be left (then false). The selections move, and `window`'s sidebar (the row starts closing,
    /// the next row is selected) and content show it in this turn, not an observation hop later.
    ///
    /// `keepsWindow` (a person's close): when `id` is the last row of the window's room, the window takes Home (the
    /// store's home workspace) first and shows it, so it stays open, never empty (audit-findings-1 C). Without Home
    /// yet (its store has not answered `ensure_home`), or when Home is the only workspace of another window, the window
    /// closes with the workspace, as before.
    static func begin(_ id: String, in window: String?, windows: WindowManager, keepsWindow: Bool = false) -> Bool {
        guard let window, let controller = windows.controller(for: window) else { return false }
        let machines = windows.services.machines
        var room = WindowProfiles.visible(windows.registry.members(of: window), profile: controller.state.profileID, machines: machines)
        if keepsWindow, !room.contains(where: { $0 != id && !ClosingWorkspaces.shared.ids.contains($0) }),
           let home = windows.services.home.homeWorkspace?.id, home != id, leavesItsWindowOpen(home, for: window, windows) {
            // Into this window (from the window that lists it, if any) and its room, selected: one transition.
            windows.claim(workspaceID: home, in: controller.state)
            room = WindowProfiles.visible(windows.registry.members(of: window), profile: controller.state.profileID, machines: machines)
        }
        guard ClosingWorkspaces.shared.begin(id, among: room) else { return false }
        // Preserve the pre-close order. ClosingWorkspaces hides `id` before
        // repairSelections runs; reconstructing the old order afterward can
        // make a last-row close fall back to the first surviving workspace.
        windows.repairSelections(previous: [window: room])
        controller.sidebar.sameTurn.syncNow(rows: true)
        controller.showWorkspace(requested: controller.state.workspaceID)
        return true
    }

    /// Whether `window` can take Home without closing another: Home is in no window, already in `window`, or in a
    /// window that keeps another workspace.
    private static func leavesItsWindowOpen(_ home: String, for window: String, _ windows: WindowManager) -> Bool {
        guard let owner = windows.registry.value.owner(of: home), owner != window else { return true }
        return windows.registry.members(of: owner).contains { $0 != home }
    }
}
