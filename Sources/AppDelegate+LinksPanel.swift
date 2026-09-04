import AppKit
import Foundation

extension AppDelegate {
    /// Opens the canonical Artifacts surface for the focused workspace.
    @discardableResult
    func openArtifactsPanelForFocusedWorkspace(for tabManager: TabManager?) -> Bool {
        guard let workspace = tabManager?.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
            return false
        }
        return workspace.openOrFocusWorkspaceArtifactsSurface(inPane: paneId, focus: true) != nil
    }

    /// Compatibility alias for callers and snapshots written by the Links release.
    @discardableResult
    func openLinksPanelForFocusedWorkspace(for tabManager: TabManager?) -> Bool {
        openArtifactsPanelForFocusedWorkspace(for: tabManager)
    }
}
