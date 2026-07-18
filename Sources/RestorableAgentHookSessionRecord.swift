import CmuxFoundation
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
    /// False for a session observed beneath another agent on the same surface.
    /// Child sessions remain visible in history but never become restoration candidates.
    var restoreAuthority: Bool? = nil
    /// Canonical process generations supersede the compatibility authority bit.
    var runs: [CmuxAgentSessionRunAuthorityProjection.Run]? = nil
    var activeRunId: String? = nil
    var completedAt: TimeInterval? = nil
    var workloads: [AgentWorkloadRecord]? = nil
    var sessionState: AgentSessionLifecycleState? = nil
    var agentLifecycle: AgentHibernationLifecycleState?
    var updatedAt: TimeInterval

    var effectiveHibernationLifecycle: AgentHibernationLifecycleState? {
        workloads?.contains { $0.keepsSessionBusy && $0.phase.isActive } == true ? .running : agentLifecycle
    }

    var projectedRestoreAuthority: Bool {
        CmuxAgentSessionRunAuthorityProjection().projectedRestoreAuthority(
            recordRestoreAuthority: restoreAuthority,
            runs: runs,
            activeRunId: activeRunId
        )
    }
}
