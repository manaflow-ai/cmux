import Foundation

struct DockRemoteExecutionContext: Hashable, Sendable {
    let workspaceID: UUID
    let foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth?
}
