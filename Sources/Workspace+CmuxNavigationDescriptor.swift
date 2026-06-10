import Foundation

extension Workspace {
    /// Snapshots this workspace's navigable identity — runtime and
    /// restart-stable ids for the workspace and each tab in the layout — into
    /// the pure descriptor ``CmuxNavigationTargetResolver`` resolves deep links
    /// against. Panels not present in the bonsplit layout are excluded, matching
    /// what `focusTab` can actually navigate to.
    var cmuxNavigationDescriptor: CmuxNavigationTargetResolver.WorkspaceDescriptor {
        CmuxNavigationTargetResolver.WorkspaceDescriptor(
            workspaceId: id,
            stableId: stableId,
            paneIds: bonsplitController.allPaneIds.map(\.id),
            surfaces: panels.compactMap { panelId, panel in
                guard surfaceIdFromPanelId(panelId) != nil else { return nil }
                return CmuxNavigationTargetResolver.SurfaceDescriptor(
                    panelId: panelId,
                    stableSurfaceId: panel.stableSurfaceId
                )
            }
        )
    }
}
