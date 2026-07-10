import Bonsplit
import Foundation

@MainActor
extension TerminalController {
    /// Drops a projected pane's control refs when it leaves mirror topology.
    /// Installed as `RemoteTmuxWindowMirror.onControlPaneRemoved`.
    static func remoteTmuxControlPaneRemovalHandler() -> (PaneID, UUID) -> Void {
        { [weak controller = TerminalController.shared] paneID, surfaceID in
            controller?.cleanupSurfaceState(surfaceIds: [surfaceID], paneIds: [paneID.id])
        }
    }

    func v2RefreshRemoteTmuxAwarePaneAndSurfaceRefs(workspace: Workspace) {
        for paneID in workspace.bonsplitController.allPaneIds {
            let panelIDs = workspace.bonsplitController.tabs(inPane: paneID).compactMap {
                workspace.panelIdFromSurfaceId($0.id)
            }
            var hasOrdinarySurface = false
            for panelID in panelIDs {
                if let mirror = workspace.remoteTmuxWindowMirror(forPanelId: panelID) {
                    for pane in mirror.controlPanes() {
                        _ = v2Ref(kind: .pane, uuid: pane.paneID.id)
                        _ = v2Ref(kind: .surface, uuid: pane.panel.id)
                    }
                } else {
                    hasOrdinarySurface = true
                    _ = v2Ref(kind: .surface, uuid: panelID)
                }
            }
            if hasOrdinarySurface {
                _ = v2Ref(kind: .pane, uuid: paneID.id)
            }
        }
    }
}
