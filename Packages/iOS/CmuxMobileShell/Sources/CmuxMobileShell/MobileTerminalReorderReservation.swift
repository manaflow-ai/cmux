internal import CmuxMobileShellModel
internal import Foundation

struct MobileWorkspaceOwnerIdentity: Hashable, Sendable {
    let ownerMacID: String?
    let rpcWorkspaceID: MobileWorkspacePreview.ID

    init(ownerMacID: String?, rpcWorkspaceID: MobileWorkspacePreview.ID) {
        self.ownerMacID = ownerMacID?.isEmpty == false ? ownerMacID : nil
        self.rpcWorkspaceID = rpcWorkspaceID
    }

    init(workspace: MobileWorkspacePreview) {
        self.init(
            ownerMacID: workspace.macDeviceID,
            rpcWorkspaceID: workspace.rpcWorkspaceID
        )
    }

    init(fallbackPresentationID: MobileWorkspacePreview.ID) {
        self.init(ownerMacID: nil, rpcWorkspaceID: fallbackPresentationID)
    }
}

/// One synchronous claim on the shared terminal-reorder owner.
public struct MobileTerminalReorderReservation: Equatable, Sendable {
    let token: UUID
    let ownerIdentity: MobileWorkspaceOwnerIdentity
    let workspaceID: MobileWorkspacePreview.ID
    let paneID: MobilePanePreview.ID

    init(
        ownerIdentity: MobileWorkspaceOwnerIdentity,
        workspaceID: MobileWorkspacePreview.ID,
        paneID: MobilePanePreview.ID
    ) {
        token = UUID()
        self.ownerIdentity = ownerIdentity
        self.workspaceID = workspaceID
        self.paneID = paneID
    }
}
