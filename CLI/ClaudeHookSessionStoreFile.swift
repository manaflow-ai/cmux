import Foundation

struct ClaudeHookClearBackgroundWorkTransfer: Codable {
    /// Session retired by `SessionEnd(clear)`; its late hooks stay stale until
    /// the replacement clear session consumes this one-shot boundary.
    let sourceSessionId: String?
    let workspaceId: String?
    let pid: Int?
    let pidStartSeconds: Int64?
    let pidStartMicroseconds: Int64?
    let updatedAt: TimeInterval
    /// Creator-owned expiry so another hook process cannot shorten the handoff.
    let expiresAt: TimeInterval?
    /// Ownership always crosses a clear boundary; surviving work is independent.
    /// Missing on legacy transfers, which were only created when work survived.
    let preservedPendingBackgroundWork: Bool?
}

struct ClaudeHookRetiredSessionRecord: Codable {
    /// Process generation that owned this session when a lifecycle boundary
    /// retired it. Ordinary activity from this identity can never revive it.
    let pid: Int?
    let pidStartSeconds: Int64?
    let pidStartMicroseconds: Int64?
    let updatedAt: TimeInterval
}

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
    // One-shot pane ownership transfer for `/clear`: Claude ends the old
    // session before starting the new one even when background work survives.
    var clearBackgroundWorkTransfersBySurface: [String: ClaudeHookClearBackgroundWorkTransfer] = [:]
    // Durable session authority retired by `/clear`. Unlike the pane-scoped
    // one-shot transfer above, this survives successor startup so delayed
    // activity cannot recreate a consumed pre-clear session.
    var retiredSessions: [String: ClaudeHookRetiredSessionRecord] = [:]
    var agentHookFailureReportTimestamps: [String: TimeInterval] = [:]

    enum CodingKeys: String, CodingKey {
        case version
        case sessions
        case pendingSupersededSessionCleanup
        case activeSessionsByWorkspace
        case activeSessionsBySurface
        case clearBackgroundWorkTransfersBySurface
        case retiredSessions
        case agentHookFailureReportTimestamps
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
        clearBackgroundWorkTransfersBySurface = try container.decodeIfPresent(
            [String: ClaudeHookClearBackgroundWorkTransfer].self,
            forKey: .clearBackgroundWorkTransfersBySurface
        ) ?? [:]
        retiredSessions = try container.decodeIfPresent(
            [String: ClaudeHookRetiredSessionRecord].self,
            forKey: .retiredSessions
        ) ?? [:]
        agentHookFailureReportTimestamps = try container.decodeIfPresent(
            [String: TimeInterval].self,
            forKey: .agentHookFailureReportTimestamps
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
        if !clearBackgroundWorkTransfersBySurface.isEmpty {
            try container.encode(
                clearBackgroundWorkTransfersBySurface,
                forKey: .clearBackgroundWorkTransfersBySurface
            )
        }
        if !retiredSessions.isEmpty {
            try container.encode(retiredSessions, forKey: .retiredSessions)
        }
        if !agentHookFailureReportTimestamps.isEmpty {
            try container.encode(agentHookFailureReportTimestamps, forKey: .agentHookFailureReportTimestamps)
        }
    }
}
