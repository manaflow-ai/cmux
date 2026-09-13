import Foundation

extension CloudWorkspaceRenameService {
    /// Applies accepted cmux-tui terminal cwd values to projected Cloud panels.
    ///
    /// - Parameters:
    ///   - localWorkspaceID: The local workspace whose projected panels are updated.
    ///   - catalog: The authoritative surface catalog containing projections and resources.
    @MainActor
    func updateCloudDirectories(localWorkspaceID: UUID, catalog: SurfaceCatalog) {
        guard let workspace = environment.workspace(localWorkspaceID) else { return }
        let snapshot = catalog.snapshot
        let resourcesByID = Dictionary(
            snapshot.resources.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for projection in snapshot.projections
            where projection.workspaceID == localWorkspaceID && !projection.resource.machine.isLocal {
            guard let resource = resourcesByID[projection.resource] else { continue }
            if resource.kind == .terminal {
                workspace.updateCloudPanelDirectory(panelId: projection.panelID, directory: resource.detail)
            } else {
                workspace.clearRemotePanelDirectory(panelId: projection.panelID)
            }
        }
    }
}
