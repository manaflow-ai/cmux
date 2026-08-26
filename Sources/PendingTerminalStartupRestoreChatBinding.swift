import CmuxAgentChat
import Foundation

/// Deferred chat binding retargeted to the topology that commits a terminal restore.
struct PendingTerminalStartupRestoreChatBinding {
    let sessionID: String
    let source: String
    let workingDirectory: String?

    func intent(panelID: UUID, workspaceID: UUID) -> AgentChatResumeIntent {
        AgentChatResumeIntent(
            sessionID: sessionID,
            source: source,
            surfaceID: panelID.uuidString,
            workspaceID: workspaceID.uuidString,
            workingDirectory: workingDirectory
        )
    }
}
