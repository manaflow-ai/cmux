import Foundation

extension CloudWorkspaceRenameService {
    /// Admission uses the actual placement and all its local projections. An agent
    /// cannot overwrite an explicit label just because its own pane is stale.
    @MainActor
    func admitsTerminalRename(
        workspace: Workspace,
        panelID: UUID,
        resource: SurfaceResource,
        source: Workspace.CustomTitleSource,
        catalog: SurfaceCatalog
    ) -> Bool {
        guard catalog.provider(for: resource.machine) != nil,
              let tabID = remoteTabID(for: catalog.projection(forPanel: panelID), resource: resource) else { return false }
        guard source == .auto else { return true }
        for projection in catalog.projections where projection.resource == resource.id {
            guard remoteTabID(for: projection, resource: resource) == tabID,
                  let owner = environment.workspace(projection.workspaceID) else { continue }
            if owner.panelCustomTitles[projection.panelID] != nil,
               (owner.panelCustomTitleSources[projection.panelID] ?? .user) == .user { return false }
        }
        let accepted = catalog.pendingCloudRenameName(for: .tab(machine: resource.machine, id: tabID))
            ?? resource.remoteViews?.first(where: { $0.tabID == tabID })?.name ?? ""
        return accepted.isEmpty || (workspace.panelCustomTitleSources[panelID] == .auto
            && workspace.panelCustomTitles[panelID] == accepted)
    }
}
