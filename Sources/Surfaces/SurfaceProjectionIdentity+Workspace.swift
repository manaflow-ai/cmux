import Foundation

extension SurfaceProjectionIdentity {
    /// Joins one captured owner index without searching every workspace for each projection.
    @MainActor
    static func capture(
        projections: [SurfaceProjection],
        workspacesByID: [UUID: Workspace]
    ) -> [SurfaceProjection: SurfaceProjectionIdentity] {
        var identities: [SurfaceProjection: SurfaceProjectionIdentity] = [:]
        for projection in projections {
            identities[projection] = Self(projection: projection, workspace: workspacesByID[projection.workspaceID])
        }
        return identities
    }

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
