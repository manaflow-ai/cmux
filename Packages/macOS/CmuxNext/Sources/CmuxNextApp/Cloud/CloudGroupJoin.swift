import CmuxNextDaemon
import CmuxNextSidebar

/// A new Cloud workspace joins the sidebar's Cloud group (`sidebar.cloudGroup`,
/// on by default; `SidebarDocStore.joinCloudGroup`). Only the Cloud creation
/// paths call it, once, for a workspace they made: local and SSH workspaces
/// never join, and one the person moves out is never moved back.
@MainActor
struct CloudGroupJoin {
    let services: AppServices

    /// Puts the new Cloud workspace `workspaceID` into the Cloud group, when
    /// the setting is on and the sidebar document is live.
    func join(_ workspaceID: String) {
        guard services.settings?.snapshot.sidebarSections.cloudGroup ?? true, SidebarDocWiring.isActive,
              let store = SidebarDocStore.current, let (workspace, daemon) = services.machines.workspace(id: workspaceID),
              let session = daemon.store.registryID, let resource = workspace.resourceID else { return }
        store.joinCloudGroup([SidebarDocWorkspaceRef(sessionID: session, workspaceID: resource.rawValue)])
    }
}
