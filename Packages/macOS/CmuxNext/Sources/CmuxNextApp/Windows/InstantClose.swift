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
    /// `tookHome` hears the Home claim (Home's window before it), so a cancelled close can give it back (``giveBack``).
    static func begin(_ id: String, in window: String?, windows: WindowManager, keepsWindow: Bool = false,
                      tookHome: (InstantClose.TookHome) -> Void = { _ in }) -> Bool {
        guard let window, let controller = windows.controller(for: window) else { return false }
        let machines = windows.services.machines
        var room = WindowProfiles.visible(windows.registry.members(of: window), profile: controller.state.profileID, machines: machines)
        if keepsWindow, !room.contains(where: { $0 != id && !ClosingWorkspaces.shared.ids.contains($0) }),
           let home = windows.services.home.homeWorkspace?.id, home != id, canTake(home, into: window, windows) {
            let from = windows.registry.value.owner(of: home)
            // Into this window (from the window that lists it, if any) and its room, selected: one transition.
            windows.claim(workspaceID: home, in: controller.state)
            tookHome(TookHome(home: home, from: from, wasShownThere: from.flatMap(windows.controller(for:))?.state.workspaceID == home))
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

    /// Home as a close took it: its id, the window that listed it, and whether that window showed it.
    struct TookHome {
        var home: String
        var from: String?
        var wasShownThere: Bool
    }

    /// Whether `window` can take Home: a normal window (Home never enters an incognito one, whose close discards its
    /// workspaces), and Home is in no window, already in `window`, or in a window that keeps another workspace and does
    /// not show Home now (a person looking at Home there keeps it).
    private static func canTake(_ home: String, into window: String, _ windows: WindowManager) -> Bool {
        let registry = windows.registry.value
        guard !registry.isIncognito(window), !registry.crossesIncognito([home], to: window) else { return false }
        guard let owner = registry.owner(of: home), owner != window else { return true }
        let shownThere = windows.controller(for: owner)?.state.workspaceID == home
        return !shownThere && windows.registry.members(of: owner).contains { $0 != home }
    }

    /// A cancelled close (`WorkspaceCloseFlow`'s restore): Home goes back to the open window it came from, selected
    /// there if it was shown; with no such window it stays.
    static func giveBack(_ took: TookHome, from state: WindowState, windows: WindowManager) {
        guard let from = took.from, from != state.id, windows.registry.value.window(from)?.isOpen == true,
              let target = windows.controller(for: from), windows.registry.value.owner(of: took.home) == state.id else { return }
        windows.claim(workspaceID: took.home, in: target.state, select: took.wasShownThere)
    }
}
