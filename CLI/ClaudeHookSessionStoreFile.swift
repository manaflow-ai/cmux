import Foundation

struct ClaudeHookSessionStoreFile: Codable {
    var version: Int = 1
    var sessions: [String: ClaudeHookSessionRecord] = [:]
    // Superseded records stay durable for retry without remaining visible to
    // store consumers as simultaneously live session claimants.
    var pendingSupersededSessionCleanup: [String: ClaudeHookSessionRecord] = [:]
    var activeSessionsByWorkspace: [String: ClaudeHookActiveSessionRecord] = [:]
    // The pane-scoped active boundary. The workspace slot only remembers ONE
    // active session, so once another pane promotes (e.g. a forked conversation
    // in a split), it can no longer prove that a late hook from a superseded
    // session in this pane is stale. Keyed by surface id.
    // https://github.com/manaflow-ai/cmux/issues/5908
    var activeSessionsBySurface: [String: ClaudeHookActiveSessionRecord] = [:]
    var agentHookFailureReportTimestamps: [String: TimeInterval] = [:]
    /// Bounded lookup index for Cursor approvals, keyed by stable surface id.
    var pendingCursorApprovalSessionsBySurface: [String: [String]] = [:]
    /// Exact pending-session count for each stable surface identity. The ID
    /// list is capped, so this count preserves sibling detection when the cap
    /// is exceeded.
    var pendingCursorApprovalSessionCountsBySurface: [String: Int] = [:]
    /// Surfaces whose capped ID list has overflowed. The flag remains set until
    /// the count reaches zero so an omitted session cannot be mistaken for the
    /// current completion after the retained IDs drain.
    var pendingCursorApprovalSurfaceOverflow: [String: Bool] = [:]
    var pendingCursorApprovalIndexInitialized: Bool = false

    enum CodingKeys: String, CodingKey {
        case version
        case sessions
        case pendingSupersededSessionCleanup
        case activeSessionsByWorkspace
        case activeSessionsBySurface
        case agentHookFailureReportTimestamps
        case pendingCursorApprovalSessionsBySurface
        case pendingCursorApprovalSessionCountsBySurface
        case pendingCursorApprovalSurfaceOverflow
        case pendingCursorApprovalIndexInitialized
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sessions = try container.decodeIfPresent([String: ClaudeHookSessionRecord].self, forKey: .sessions) ?? [:]
        pendingSupersededSessionCleanup = try container.decodeIfPresent(
            [String: ClaudeHookSessionRecord].self,
            forKey: .pendingSupersededSessionCleanup
        ) ?? [:]
        activeSessionsByWorkspace = try container.decodeIfPresent(
            [String: ClaudeHookActiveSessionRecord].self,
            forKey: .activeSessionsByWorkspace
        ) ?? [:]
        activeSessionsBySurface = try container.decodeIfPresent(
            [String: ClaudeHookActiveSessionRecord].self,
            forKey: .activeSessionsBySurface
        ) ?? [:]
        agentHookFailureReportTimestamps = try container.decodeIfPresent(
            [String: TimeInterval].self,
            forKey: .agentHookFailureReportTimestamps
        ) ?? [:]
        pendingCursorApprovalSessionsBySurface = try container.decodeIfPresent(
            [String: [String]].self,
            forKey: .pendingCursorApprovalSessionsBySurface
        ) ?? [:]
        pendingCursorApprovalSessionCountsBySurface = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .pendingCursorApprovalSessionCountsBySurface
        ) ?? [:]
        pendingCursorApprovalSurfaceOverflow = try container.decodeIfPresent(
            [String: Bool].self,
            forKey: .pendingCursorApprovalSurfaceOverflow
        ) ?? [:]
        pendingCursorApprovalIndexInitialized = try container.decodeIfPresent(
            Bool.self,
            forKey: .pendingCursorApprovalIndexInitialized
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(sessions, forKey: .sessions)
        if !pendingSupersededSessionCleanup.isEmpty {
            try container.encode(pendingSupersededSessionCleanup, forKey: .pendingSupersededSessionCleanup)
        }
        if !activeSessionsByWorkspace.isEmpty {
            try container.encode(activeSessionsByWorkspace, forKey: .activeSessionsByWorkspace)
        }
        if !activeSessionsBySurface.isEmpty {
            try container.encode(activeSessionsBySurface, forKey: .activeSessionsBySurface)
        }
        if !agentHookFailureReportTimestamps.isEmpty {
            try container.encode(agentHookFailureReportTimestamps, forKey: .agentHookFailureReportTimestamps)
        }
        if !pendingCursorApprovalSessionsBySurface.isEmpty {
            try container.encode(
                pendingCursorApprovalSessionsBySurface,
                forKey: .pendingCursorApprovalSessionsBySurface
            )
        }
        if !pendingCursorApprovalSessionCountsBySurface.isEmpty {
            try container.encode(
                pendingCursorApprovalSessionCountsBySurface,
                forKey: .pendingCursorApprovalSessionCountsBySurface
            )
        }
        if !pendingCursorApprovalSurfaceOverflow.isEmpty {
            try container.encode(
                pendingCursorApprovalSurfaceOverflow,
                forKey: .pendingCursorApprovalSurfaceOverflow
            )
        }
        if pendingCursorApprovalIndexInitialized {
            try container.encode(true, forKey: .pendingCursorApprovalIndexInitialized)
        }
    }
}
