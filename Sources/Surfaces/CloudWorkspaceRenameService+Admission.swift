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
        let pending = catalog.pendingCloudRenameName(for: .tab(machine: resource.machine, id: tabID))
        let accepted = pending ?? resource.remoteViews?.first(where: { $0.tabID == tabID })?.name ?? ""
        if accepted.isEmpty { return true }
        // An accepted name reconciles locally as `.remote`, so the daemon's
        // name authority says whether an agent owns it and may replace it.
        if pending == nil, let tab = catalog.cloudStates[resource.machine]?.lookupIndex.tab(id: tabID),
           tab.name == accepted, tab.nameAuthority?.source == .auto { return true }
        return workspace.panelCustomTitleSources[panelID] == .auto
            && workspace.panelCustomTitles[panelID] == accepted
    }
}
