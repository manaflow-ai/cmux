import CmuxCore

struct SidebarRootObservationState: Equatable {
    let currentDirectory: String
    let remoteConfiguration: WorkspaceRemoteConfiguration?
    let remoteConnectionState: WorkspaceRemoteConnectionState
    let remoteConnectionDetail: String?
    let remoteDaemonStatus: WorkspaceRemoteDaemonStatus
    let activeRemoteTerminalSessionCount: Int
}
