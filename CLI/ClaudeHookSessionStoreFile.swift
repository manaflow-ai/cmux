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
    /// Bounded lookup index for Cursor approvals, keyed by workspace/surface.
    var pendingCursorApprovalSessionsBySurface: [String: [String]] = [:]

    enum CodingKeys: String, CodingKey {
        case version
        case sessions
        case pendingSupersededSessionCleanup
        case activeSessionsByWorkspace
        case activeSessionsBySurface
        case agentHookFailureReportTimestamps
        case pendingCursorApprovalSessionsBySurface
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
    }
}
