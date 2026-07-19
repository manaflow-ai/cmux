import Foundation

struct RestorableAgentHookSessionRecord: Codable, Sendable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var transcriptPath: String?
    var pid: Int?
    var launchCommand: AgentLaunchCommandSnapshot?
    /// Last hook-observed agent permission mode (e.g. Claude's `permission_mode`).
    var lastPermissionMode: String?
    var isRestorable: Bool?
    var agentLifecycle: AgentHibernationLifecycleState?
    var updatedAt: TimeInterval
}
