import Foundation

extension SurfaceProjectionIdentity {
    /// A stale or mismatched owner cannot provide a durable join for this projection.
    @MainActor
    init?(projection: SurfaceProjection, workspace: Workspace?) {
        guard let workspace,
              workspace.id == projection.workspaceID,
              let panel = workspace.panels[projection.panelID],
              panel.id == projection.panelID else { return nil }
        self.init(stableSurfaceID: panel.stableSurfaceId, stableWorkspaceID: workspace.stableId)
    }
}
