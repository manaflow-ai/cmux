import Foundation

extension SurfaceCatalog {
    func projection(forPanel panelID: UUID) -> SurfaceProjection? {
        projections.first { $0.panelID == panelID }
    }


    /// Restored projections retain their owner even before the provider reconnects.
    func machineOwningPanel(_ panelID: UUID) -> SurfaceMachineID? {
        pendingRestoredProjections.machineOwningPanel(panelID)
            ?? projection(forPanel: panelID)?.resource.machine
    }

    func validateOwnership(of resources: [SurfaceResourceID], at destination: SurfaceDestination) throws {
        let workspace = cloudWorkspaceRenameService.environment.workspace(destination.workspaceID)
            ?? Workspace.liveWorkspace(id: destination.workspaceID)
        let policy = workspace?.surfaceOwnershipPolicy
        if let rejection = policy?.rejection(for: resources) { throw rejection }
    }
}
