import CmuxNextDaemon

/// Whether launch gives the tree its first workspace (`WindowManager.restore`).
enum FirstWorkspace {
    /// A tree with no workspace of the user's own gets one at launch.
    /// Leftover incognito and ephemeral workspaces do not count, nor does
    /// the store's home workspace, which exists from the first connect
    /// (`HomeService.ensureHomeWorkspace`) and holds only the Chief tab.
    /// `home` is the workspace `ensure_home` named: Home even while the tree
    /// does not report its kind yet (a fresh store's first snapshot).
    static func isNeeded(_ workspaces: [WorkspaceModel], leftover: [String], home: ResourceID? = nil) -> Bool {
        !workspaces.contains { workspace in
            !leftover.contains(workspace.id) && !workspace.ephemeral && workspace.kind != "home"
                && (home == nil || workspace.resourceID != home)
        }
    }
}

/// The launch's first workspace (`WindowManager.restore`): made on its New
/// Tab page when the tree has no workspace of the user's own, then shown
/// at once instead of the Home page (Lawrence 2026-10-09: "drop user into
/// main screen asap").
@MainActor
struct FirstWorkspaceLaunch {
    let manager: WindowManager

    /// The new workspace's id, or nil when the tree has one of the user's
    /// own. A fresh store's snapshot can show Home before its kind row, so
    /// this decides once `ensure_home` answered, with the workspace it named.
    func create(leftover: [String]) async -> String? {
        let services = manager.services
        await services.home.awaitHomeEnsured()
        guard FirstWorkspace.isNeeded(services.daemon.store.workspaces, leftover: leftover, home: services.home.homeWorkspaceID) else { return nil }
        return await manager.createWorkspace(newTabPage: true)
    }

    /// Shows `workspaceID` (the one `create` made) in its window.
    func land(_ workspaceID: String?) {
        guard let workspaceID, manager.services.machines.workspace(id: workspaceID) != nil else { return }
        _ = manager.reveal(workspaceID: workspaceID)
    }
}
