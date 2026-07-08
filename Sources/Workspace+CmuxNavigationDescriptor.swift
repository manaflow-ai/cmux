import Foundation

extension Workspace {
    /// Snapshots durable-link identity for this workspace and navigable tabs.
    ///
    /// The descriptor includes runtime ids for same-session links and persisted
    /// restart-stable ids for links copied before an app restart. Panels not in
    /// the bonsplit layout are excluded, matching what `focusTab` can navigate to.
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
