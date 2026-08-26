import Bonsplit
import Foundation

@MainActor
extension TerminalController {
    static func remoteTmuxControlPaneRemovalHandler() -> (PaneID, UUID?) -> Void {
        { [weak controller = TerminalController.shared] paneID, surfaceID in
            controller?.cleanupSurfaceState(
                surfaceIds: surfaceID.map { [$0] } ?? [],
                paneIds: [paneID.id]
            )
        }
    }

    static func remoteTmuxControlSurfaceRemovalHandler(
        workspaceID: UUID? = nil
    ) -> (UUID) -> Void {
        { [weak controller = TerminalController.shared] surfaceID in
            if let workspaceID {
                AppDelegate.shared?.notificationStore?.clearNotifications(
                    forTabId: workspaceID,
                    surfaceId: surfaceID
                )
            }
            controller?.cleanupSurfaceState(
                surfaceIds: [surfaceID],
                workspaceID: workspaceID
            )
        }
    }

    func v2RefreshRemoteTmuxAwarePaneAndSurfaceRefs(workspace: Workspace) {
        for paneID in workspace.bonsplitController.allPaneIds {
            let panelIDs = workspace.bonsplitController.tabs(inPane: paneID).compactMap {
                workspace.panelIdFromSurfaceId($0.id)
            }
            var hasOrdinarySurface = false
            for panelID in panelIDs {
                if workspace.isRemoteTmuxControlContainer(panelID) {
                    for location in workspace.remoteTmuxControlPanes(containerPanelID: panelID) {
                        _ = v2Ref(kind: .pane, uuid: location.pane.paneID.id)
                        _ = v2Ref(kind: .surface, uuid: location.pane.panel.id)
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
