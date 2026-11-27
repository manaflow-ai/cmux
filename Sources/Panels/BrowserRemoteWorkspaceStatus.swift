import CmuxCore
import Foundation

/// Connection snapshot for the remote workspace a browser panel belongs to.
struct BrowserRemoteWorkspaceStatus: Equatable, Sendable {
    let target: String
    let connectionState: WorkspaceRemoteConnectionState
    let heartbeatCount: Int
    let lastHeartbeatAt: Date?
}
