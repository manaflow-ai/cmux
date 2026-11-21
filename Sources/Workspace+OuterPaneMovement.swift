import Bonsplit

extension Workspace {
    /// Promotes the focused pane to a new 50/50 split at a workspace root edge.
    /// The pane and every live surface it owns retain their identities.
    @discardableResult
    func moveFocusedPane(to movement: PaneOuterMovement) -> Bool {
        guard layoutMode != .canvas,
              !isRemoteTmuxMirror,
              let panelId = focusedPanelId,
              panels[panelId] != nil,
              let paneId = paneId(forPanelId: panelId) else {
            return false
        }
        return bonsplitController.movePane(
            paneId,
            toRootEdge: movement.rootSplitEdge
        )
    }
}
