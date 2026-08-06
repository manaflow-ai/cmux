import Foundation
import CmuxCore

/// Selected-workspace values that determine the file explorer's directory.
struct SelectedWorkspaceDirectorySnapshot: Equatable {
    let workspaceId: UUID?
    let currentDirectory: String?
    let remoteConfiguration: WorkspaceRemoteConfiguration?
    let remoteConnectionState: WorkspaceRemoteConnectionState?
    let remoteConnectionDetail: String?
    let remoteDaemonStatus: WorkspaceRemoteDaemonStatus?
    let activeRemoteTerminalSessionCount: Int
}
