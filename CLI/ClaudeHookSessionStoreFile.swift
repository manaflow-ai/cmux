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
    // SessionEnd leaves a short-lived tombstone so an asynchronous task hook
    // cannot recreate a session record after the lifecycle owner consumed it.
    var endedSessionIDs: [String: TimeInterval] = [:]
    // Generation-qualified end boundaries let a timed-out SessionEnd suppress
    // a late task hook without preventing a later SessionStart from reusing the
    // same session identifier.
    var endedSessionGenerationStarts: [String: TimeInterval] = [:]
    // Retired task-list proofs prevent a deleted team directory from being
    // re-admitted by the compatibility identity scan.
    var retiredClaudeTaskLists: [String: TimeInterval] = [:]
    // Latest pending task-sync token per task-store scope. Older async hook
    // processes observe replacement and exit before doing expensive work.
    var claudeTaskSyncLatestTokens: [String: String] = [:]
    // Monotonic claim ordering assigned inside the durable state transaction.
    var claudeTaskSyncGeneration: UInt64 = 0
    // Legacy owners whose cleanup exceeded one bounded hook pass. The next
    // task hook drains another page before completing its own transition.
    var pendingLegacyClaudeTaskOwnerCleanup: [
        String: LegacyClaudeTaskOwnerCleanupRecord
    ] = [:]
    // A second bounded tier preserves cleanup proofs when the ordinary queue
    // is saturated; entries are drained before declaring a TeamDelete complete.
    var pendingLegacyClaudeTaskOwnerCleanupOverflowEntries: [
        String: LegacyClaudeTaskOwnerCleanupRecord
    ] = [:]
    // Last-resort spill tier. It is intentionally durable rather than a
    // boolean-only marker so sessionless fallback destinations cannot vanish.
    var pendingLegacyClaudeTaskOwnerCleanupSpill: [
        String: LegacyClaudeTaskOwnerCleanupRecord
    ] = [:]
    var pendingLegacyClaudeTaskOwnerCleanupOverflowCursor: String?
    var pendingLegacyClaudeTaskOwnerCleanupOverflow = false
    // Automatic-team task identity is list-scoped rather than session-scoped:
    // leader and teammate hooks can run in independent Claude sessions.
    var claudeTeamTaskBindings: [String: ClaudeHookTeamTaskBindingRecord] = [:]
    // Task-list ownership outlives individual sessions, and explicitly
    // configured lists can span several, so deletion destinations are durable.
    var claudeTaskListDestinations: [String: ClaudeHookTaskListDestinationRecord] = [:]
    var agentHookFailureReportTimestamps: [String: TimeInterval] = [:]

    enum CodingKeys: String, CodingKey {
        case version
        case sessions
        case pendingSupersededSessionCleanup
        case activeSessionsByWorkspace
        case activeSessionsBySurface
        case endedSessionIDs
        case endedSessionGenerationStarts
        case retiredClaudeTaskLists
        case claudeTaskSyncLatestTokens
        case claudeTaskSyncGeneration
        case pendingLegacyClaudeTaskOwnerCleanup
        case pendingLegacyClaudeTaskOwnerCleanupOverflowEntries
        case pendingLegacyClaudeTaskOwnerCleanupSpill
        case pendingLegacyClaudeTaskOwnerCleanupOverflowCursor
        case pendingLegacyClaudeTaskOwnerCleanupOverflow
        case claudeTeamTaskBindings
        case claudeTaskListDestinations
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
        endedSessionIDs = try container.decodeIfPresent(
            [String: TimeInterval].self,
            forKey: .endedSessionIDs
        ) ?? [:]
        endedSessionGenerationStarts = try container.decodeIfPresent(
            [String: TimeInterval].self,
            forKey: .endedSessionGenerationStarts
        ) ?? [:]
        retiredClaudeTaskLists = try container.decodeIfPresent(
            [String: TimeInterval].self,
            forKey: .retiredClaudeTaskLists
        ) ?? [:]
        claudeTaskSyncLatestTokens = try container.decodeIfPresent(
            [String: String].self,
            forKey: .claudeTaskSyncLatestTokens
        ) ?? [:]
        claudeTaskSyncGeneration = try container.decodeIfPresent(
            UInt64.self,
            forKey: .claudeTaskSyncGeneration
        ) ?? 0
        if let records = try? container.decode(
            [String: LegacyClaudeTaskOwnerCleanupRecord].self,
            forKey: .pendingLegacyClaudeTaskOwnerCleanup
        ) {
            pendingLegacyClaudeTaskOwnerCleanup = records
        } else {
            // Stores written by the first continuation implementation kept
            // only directory names. Preserve those entries and let the store
            // rediscover their destinations on the next hook.
            let legacyDirectories = try container.decodeIfPresent(
                [String].self,
                forKey: .pendingLegacyClaudeTaskOwnerCleanup
            ) ?? []
            pendingLegacyClaudeTaskOwnerCleanup = legacyDirectories.reduce(
                into: [:]
            ) { records, directoryName in
                guard !directoryName.isEmpty else { return }
                records[directoryName] = records[directoryName]
                    ?? LegacyClaudeTaskOwnerCleanupRecord(workspaceIDs: [])
            }
        }
        pendingLegacyClaudeTaskOwnerCleanupOverflowEntries = try container.decodeIfPresent(
            [String: LegacyClaudeTaskOwnerCleanupRecord].self,
            forKey: .pendingLegacyClaudeTaskOwnerCleanupOverflowEntries
        ) ?? [:]
        pendingLegacyClaudeTaskOwnerCleanupSpill = try container.decodeIfPresent(
            [String: LegacyClaudeTaskOwnerCleanupRecord].self,
            forKey: .pendingLegacyClaudeTaskOwnerCleanupSpill
        ) ?? [:]
        pendingLegacyClaudeTaskOwnerCleanupOverflowCursor = try container.decodeIfPresent(
            String.self,
            forKey: .pendingLegacyClaudeTaskOwnerCleanupOverflowCursor
        )
        pendingLegacyClaudeTaskOwnerCleanupOverflow = try container.decodeIfPresent(
            Bool.self,
            forKey: .pendingLegacyClaudeTaskOwnerCleanupOverflow
        ) ?? false
        claudeTeamTaskBindings = try container.decodeIfPresent(
            [String: ClaudeHookTeamTaskBindingRecord].self,
            forKey: .claudeTeamTaskBindings
        ) ?? [:]
        claudeTaskListDestinations = try container.decodeIfPresent(
            [String: ClaudeHookTaskListDestinationRecord].self,
            forKey: .claudeTaskListDestinations
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
        if !endedSessionIDs.isEmpty {
            try container.encode(endedSessionIDs, forKey: .endedSessionIDs)
        }
        if !endedSessionGenerationStarts.isEmpty {
            try container.encode(
                endedSessionGenerationStarts,
                forKey: .endedSessionGenerationStarts
            )
        }
        if !retiredClaudeTaskLists.isEmpty {
            try container.encode(retiredClaudeTaskLists, forKey: .retiredClaudeTaskLists)
        }
        if !claudeTaskSyncLatestTokens.isEmpty {
            try container.encode(claudeTaskSyncLatestTokens, forKey: .claudeTaskSyncLatestTokens)
        }
        if claudeTaskSyncGeneration > 0 {
            try container.encode(claudeTaskSyncGeneration, forKey: .claudeTaskSyncGeneration)
        }
        if !pendingLegacyClaudeTaskOwnerCleanup.isEmpty {
            try container.encode(
                pendingLegacyClaudeTaskOwnerCleanup,
                forKey: .pendingLegacyClaudeTaskOwnerCleanup
            )
        }
        if !pendingLegacyClaudeTaskOwnerCleanupOverflowEntries.isEmpty {
            try container.encode(
                pendingLegacyClaudeTaskOwnerCleanupOverflowEntries,
                forKey: .pendingLegacyClaudeTaskOwnerCleanupOverflowEntries
            )
        }
        if !pendingLegacyClaudeTaskOwnerCleanupSpill.isEmpty {
            try container.encode(
                pendingLegacyClaudeTaskOwnerCleanupSpill,
                forKey: .pendingLegacyClaudeTaskOwnerCleanupSpill
            )
        }
        if let pendingLegacyClaudeTaskOwnerCleanupOverflowCursor {
            try container.encode(
                pendingLegacyClaudeTaskOwnerCleanupOverflowCursor,
                forKey: .pendingLegacyClaudeTaskOwnerCleanupOverflowCursor
            )
        }
        if pendingLegacyClaudeTaskOwnerCleanupOverflow {
            try container.encode(
                true,
                forKey: .pendingLegacyClaudeTaskOwnerCleanupOverflow
            )
        }
        if !claudeTeamTaskBindings.isEmpty {
            try container.encode(claudeTeamTaskBindings, forKey: .claudeTeamTaskBindings)
        }
        if !claudeTaskListDestinations.isEmpty {
            try container.encode(claudeTaskListDestinations, forKey: .claudeTaskListDestinations)
        }
        if !agentHookFailureReportTimestamps.isEmpty {
            try container.encode(agentHookFailureReportTimestamps, forKey: .agentHookFailureReportTimestamps)
        }
    }
}
