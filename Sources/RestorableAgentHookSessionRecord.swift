import CMUXAgentLaunch
import Foundation

struct RestorableAgentHookSessionRecord: Codable, Sendable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var transcriptPath: String?
    var pid: Int?
    var launchCommand: AgentLaunchCommandSnapshot?
    var isRestorable: Bool?
    var agentLifecycle: AgentHibernationLifecycleState?
    var updatedAt: TimeInterval
}

// (ci re-trigger: previous macOS CI run stuck queued ~4h; no code change)
