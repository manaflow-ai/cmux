import CmuxMobileShellModel
import Foundation

/// A workspace tap suspended while its owning Mac waits for manual-host approval.
struct PendingWorkspaceOpenIntent {
    let rowWorkspaceID: MobileWorkspacePreview.ID
    let remoteWorkspaceID: MobileWorkspacePreview.ID
    let ownerMacDeviceID: String?
    let workspaceHadUnread: Bool
    let terminalCount: Int
    let isPinned: Bool
    let macSwitchAttemptID: UUID
}
