import CmuxNextHome
import CmuxNextHomeEngine

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

    /// The new workspace's id, or nil when the tree has one of the user's own. A fresh store's
    /// snapshot can show Home before its kind row, or not yet at all, so this decides once
    /// `ensure_home` answered and (briefly) once the store lists the workspace it named.
    func create(leftover: [String]) async -> String? {
        let services = manager.services
        await services.home.awaitHomeEnsured()
        guard services.daemon.store.workspaces.needsFirstWorkspace(leftover: leftover, home: services.home.homeWorkspaceID) else { return nil }
        let landing = FirstWorkspaceLanding(launchIntoHome: HomeTunables.launchIntoHome.value, classic: services.home.dock.isClassic)
        if let home = await landing.home(ensured: services.home.homeWorkspaceID != nil, listed: { services.home.homeWorkspace?.id }) { return home }
        // This Mac's own tree is empty: its first workspace is this Mac's, whatever space the window shows.
        return await manager.createWorkspace(on: manager.services.daemon, newTabPage: true)
    }

    /// Shows `workspaceID` (the one `create` decided on, before the restore placed what was asked for meanwhile)
    /// in its window, unless a workspace of the person's own came since (dogfood gate v2.2.3, `type`).
    func land(_ workspaceID: String?, leftover: [String] = []) {
        let services = manager.services
        guard let workspaceID, services.machines.workspace(id: workspaceID) != nil,
              services.daemon.store.workspaces.needsFirstWorkspace(leftover: leftover + [workspaceID], home: services.home.homeWorkspaceID)
        else { return }
        _ = manager.reveal(workspaceID: workspaceID)
    }
}
