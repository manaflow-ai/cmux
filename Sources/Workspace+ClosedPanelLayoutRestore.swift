import Foundation

extension Workspace {
    /// Restores a closed panel's saved pane tree for both normal and fallback
    /// placement paths, keeping panel-id translation in one mutation owner.
    func restoreClosedPanelLayout(
        _ layout: SessionWorkspaceLayoutSnapshot?,
        oldPanelID: UUID,
        newPanelID: UUID
    ) {
        guard let layout,
              let restoredLayout = SessionSplitContainerLayoutCodec(controller: bonsplitController)
                .pruned(layout, keeping: Set(panels.keys).subtracting([newPanelID]).union([oldPanelID])) else {
            return
        }
        _ = SessionSplitContainerLayoutCodec(controller: bonsplitController).restoreExistingLayout(
            restoredLayout,
            panelIDMap: [oldPanelID: newPanelID],
            tabIDForPanelID: surfaceIdFromPanelId
        )
    }

}
