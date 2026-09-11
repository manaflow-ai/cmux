import Foundation

extension CloudWorkspaceRenameService {
    func updateCloudDirectories(localWorkspaceID: UUID, catalog: SurfaceCatalog) {
        guard let workspace = environment.workspace(localWorkspaceID) else { return }
        for projection in catalog.snapshot.projections where projection.workspaceID == localWorkspaceID && !projection.resource.machine.isLocal {
            guard let resource = catalog.snapshot.resources.first(where: { $0.id == projection.resource }) else { continue }
            if resource.kind == .terminal {
                workspace.updateCloudPanelDirectory(panelId: projection.panelID, directory: resource.detail)
            } else {
                workspace.clearRemotePanelDirectory(panelId: projection.panelID)
            }
        }
    }
}
