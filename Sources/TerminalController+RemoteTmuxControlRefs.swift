import Foundation

@MainActor
extension TerminalController {
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
