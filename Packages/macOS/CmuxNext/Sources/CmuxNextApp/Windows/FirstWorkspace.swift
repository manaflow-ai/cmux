import CmuxNextDaemon
import CmuxNextHome

/// Whether launch gives the tree its first workspace (`WindowManager.restore`).
enum FirstWorkspace {
    /// The Home workspace a first launch lands on (`HomeTunables.launchIntoHome`), or nil to
    /// make a New Tab workspace: the switch is off, Home is classic, or Home has no workspace yet.
    @MainActor static func landsOnHome(_ home: HomeService) -> String? {
        landing(launchIntoHome: HomeTunables.launchIntoHome.value, classic: home.dock.isClassic, home: home.homeWorkspace?.id)
    }

    /// `landsOnHome`'s rule over plain values.
    static func landing(launchIntoHome: Bool, classic: Bool, home: String?) -> String? {
        launchIntoHome && !classic ? home : nil
    }

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

/// The launch's first workspace (`WindowManager.restore`) when the tree has no workspace of
/// the user's own. By default it is Home, the Chief's workspace: the person starts with one
/// workspace and the Chief as the front door, and the workspaces its subagents open appear
/// beside it (Leo 2026-10-19: "maybe it'd be easier to just start off with one … The Chief as
/// the front door is a pretty nice onboarding"). Debug Settings > Home > First launch opens
/// Home off makes a workspace on its New Tab page and shows it instead (Lawrence 2026-10-09:
/// "drop user into main screen asap"). Classic Home has no Home workspace, so it always does.
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
        if let home = FirstWorkspace.landsOnHome(services.home) { return home }
        return await manager.createWorkspace(newTabPage: true)
    }

    /// Shows `workspaceID` (the one `create` made) in its window.
    func land(_ workspaceID: String?) {
        guard let workspaceID, manager.services.machines.workspace(id: workspaceID) != nil else { return }
        _ = manager.reveal(workspaceID: workspaceID)
    }
}
