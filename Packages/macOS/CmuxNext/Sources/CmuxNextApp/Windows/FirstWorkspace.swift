import CmuxNextDaemon
import CmuxNextHome
import CmuxNextHomeEngine

/// The launch's first workspace (`WindowManager.restore`) when the tree has no workspace of
/// the user's own. The launch rule decides (cmux-window-rules `launch::fresh_landing`, through
/// `FirstWorkspaceLanding.opens`): Home, the Chief's workspace, as the front door (Leo 2026-10-19:
/// "The Chief as the front door is a pretty nice onboarding"), or a New Tab workspace under classic
/// Home, which has no Home workspace.
@MainActor
struct FirstWorkspaceLaunch {
    let manager: WindowManager

    /// The new workspace's id, or nil when the tree has one of the user's own. Nothing is decided
    /// or made while the rule waits for Home: before `ensure_home` answers, the tree cannot tell
    /// Home from a workspace of the person's own (a fresh store's snapshot can show Home before
    /// its kind row, or not yet at all).
    func create(leftover: [String]) async -> String? {
        let home = manager.services.home, store = manager.services.daemon.store, local = manager.services.machines.local
        let opens = await FirstWorkspaceLanding().opens({
            home.ensure.freshFacts(emptyTree: store.workspaces.needsFirstWorkspace(leftover: leftover, home: home.homeWorkspaceID),
                                   classicHome: home.dock.isClassic, homeEnsured: home.homeWorkspaceID != nil,
                                   canEnsure: local.supports(DaemonCapability.workspaceKind.rawValue))
        }, listed: { home.homeWorkspace?.id })
        switch opens {
        case let .home(id)?: return id
        case .newTab?: return await manager.createWorkspace(newTabPage: true)
        case nil: return nil
        }
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
