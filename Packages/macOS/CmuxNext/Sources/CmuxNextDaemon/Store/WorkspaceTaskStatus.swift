import Foundation

/// The task lane a person pinned a workspace to (`workspace-status-v1`, the
/// workspace's `extra.task_status`), classic cmux's `WorkspaceTaskStatus`.
/// No lane (nil) is automatic. Raw values are the wire format; the cycle order
/// (Cycle Workspace Status) is cmux-window-rules `workspaces::STATUS_LANES`.
public enum WorkspaceTaskStatus: String, Codable, CaseIterable, Sendable, Hashable {
    /// Not started.
    case todo
    /// Someone (a person or an agent) is on it.
    case working
    /// Waiting on the person: the loudest lane.
    case needsAttention = "needs-attention"
    /// Up for review.
    case review
    /// Finished.
    case done
}
