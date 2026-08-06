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
            controller?.cleanupSurfaceState(surfaceIds: [surfaceID])
        }
    }
}
