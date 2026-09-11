import CmuxPanes

extension TabManager {
    /// Adjusts the focused pane in the selected local workspace by one stateless step on `axis`.
    /// Remote tmux mirrors require authoritative resizing through tmux and are intentionally excluded.
    @discardableResult
    func adjustSelectedPaneSize(
        axis: PaneAxis,
        adjustment: PaneSizeAdjustment,
        amountPixels: UInt16
    ) -> Bool {
        guard amountPixels > 0,
              let workspace = selectedWorkspace,
              workspace.layoutMode != .canvas,
              !workspace.isRemoteTmuxMirror,
              !workspace.bonsplitController.isSplitZoomed,
              let panelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: panelId) else {
            return false
        }

        let controller = workspace.bonsplitController
        let didResize = paneLayout.adjustPaneSize(
            in: controller.treeSnapshot(),
            targetPaneId: paneId.id.uuidString,
            axis: axis,
            adjustment: adjustment,
            amountPixels: amountPixels,
            controller: controller
        )
        if didResize {
            workspace.didProgrammaticallyChangeSplitGeometry()
        }
        return didResize
    }
}
