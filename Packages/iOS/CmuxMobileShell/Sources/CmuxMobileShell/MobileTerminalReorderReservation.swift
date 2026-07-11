internal import CmuxMobileShellModel
internal import Foundation

/// One synchronous claim on the shared terminal-reorder owner.
public struct MobileTerminalReorderReservation: Equatable, Sendable {
    let token: UUID
    let workspaceID: MobileWorkspacePreview.ID
    let paneID: MobilePanePreview.ID

    init(workspaceID: MobileWorkspacePreview.ID, paneID: MobilePanePreview.ID) {
        token = UUID()
        self.workspaceID = workspaceID
        self.paneID = paneID
    }
}
