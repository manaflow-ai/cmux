import Foundation

struct ClaudeHookParsedInput {
    let rawObject: [String: Any]?
    let object: [String: Any]?
    let rawFallback: String?
    let sessionId: String?
    let turnId: String?
    let cwd: String?
    let transcriptPath: String?
}

enum AgentHookRuntimeStatus: String, Codable {
    case running
    case idle
    case needsInput
    case error
}

struct ClaudeHookSessionRecord: Codable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var transcriptPath: String?
    var pid: Int?
    var launchCommand: AgentHookLaunchCommandRecord?
    /// Last hook-observed `permission_mode`, re-applied as `--permission-mode`
    /// on user-owned session restore.
    var lastPermissionMode: String?
    var isRestorable: Bool?
    var agentLifecycle: AgentHibernationLifecycleState?
    var lastSubtitle: String?
    var lastBody: String?
    var lastNotificationStatus: AgentHookNotificationStatus?
    var lastEmittedNotificationFingerprint: String?
    var lastEmittedNotificationAt: TimeInterval?
    var recentEmittedNotificationFingerprints: [String: TimeInterval]?
    var runtimeStatus: AgentHookRuntimeStatus?
    var activePromptDepth: Int?
    var activePromptTurnId: String?
    var activePromptTurnIds: [String]?
    var lastPromptTurnId: String?
    var terminalPromptTurnIds: [String]?
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
    // Auto-naming engine state (all optional so stores written before the
    // feature decode unchanged). The durable baseline advances only after a
    // confirmed title apply; the in-flight marker dedupes concurrent Stops.
    var autoNameLastTitle: String?
    var autoNameLastLineCount: Int?
    var autoNameLastNamedAt: TimeInterval?
    var autoNameInFlightAt: TimeInterval?
    /// Wall-clock of the last summarization attempt (success OR failure), so a
    /// persistently failing summarizer (rate-limited, signed out, timing out)
    /// gets the same minInterval cooldown instead of respawning every turn.
    var autoNameLastAttemptAt: TimeInterval?
    var autoNameRecentMessages: [AutoNamingTranscriptMessage]?
    var autoNameMessageSequence: Int?
    /// Whether the most recent Stop reported unfinished background work
    /// (a running `background_tasks` entry or a pending `session_crons`).
    /// Cached here because the ~60s-later `idle_prompt` Notification payload
    /// does not carry `background_tasks`, so the idle-reminder gate reads this.
    /// Optional so stores written before this field decode unchanged.
    var hadPendingBackgroundWorkAtStop: Bool?
    /// Orthogonal semantic state used by `cmux agents`. Provider adapters update
    /// these fields without storing commands, prompts, output, or environment.
    var foregroundState: AgentForegroundState? = nil
    var attentionState: AgentAttentionState? = nil
    var workloads: [AgentWorkloadRecord]? = nil
    var sessionState: AgentSessionLifecycleState? = nil
    /// Process generations observed for this logical session. Optional for
    /// compatibility with stores written before session graphs existed.
    var runs: [AgentSessionRunRecord]? = nil
    var activeRunId: String? = nil
    var runId: String? = nil
    var parentRunId: String? = nil
    var restoreAuthority: Bool? = nil
    var parentSessionId: String? = nil
    var relationship: AgentSessionRelationship? = nil
    var completedAt: TimeInterval? = nil
    /// The cmux app process that most recently owned the active run.
    var cmuxRuntime: AgentCmuxRuntimeIdentity? = nil
}

struct ClaudeHookActiveSessionRecord: Codable {
    var sessionId: String
    var turnId: String?
    var allowsNewSessionReplacement: Bool?
    var updatedAt: TimeInterval
}

struct AgentPromptSubmitResult: Sendable, Equatable {
    var accepted: Bool
    var staleTerminalTurn: Bool
    var nested: Bool
}

struct AgentPromptStopResult: Sendable, Equatable {
    var accepted: Bool
    var nested: Bool
}

struct AgentHookLaunchCommandRecord: Codable {
    var launcher: String?
    var executablePath: String?
    var arguments: [String]
    var workingDirectory: String?
    var environment: [String: String]?
    var capturedAt: TimeInterval?
    var source: String?
}

struct ClaudeHookSessionStoreFile: Codable {
    var version: Int = 2
    var sessions: [String: ClaudeHookSessionRecord] = [:]
    var activeSessionsByWorkspace: [String: ClaudeHookActiveSessionRecord] = [:]
    // The pane-scoped active boundary. The workspace slot only remembers ONE
    // active session, so once another pane promotes (e.g. a forked conversation
    // in a split), it can no longer prove that a late hook from a superseded
    // session in this pane is stale. Keyed by surface id.
    // https://github.com/manaflow-ai/cmux/issues/5908
    var activeSessionsBySurface: [String: ClaudeHookActiveSessionRecord] = [:]

    enum CodingKeys: String, CodingKey {
        case version
        case sessions
        case activeSessionsByWorkspace
        case activeSessionsBySurface
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = max(try container.decodeIfPresent(Int.self, forKey: .version) ?? 1, 2)
        sessions = try container.decodeIfPresent([String: ClaudeHookSessionRecord].self, forKey: .sessions) ?? [:]
        activeSessionsByWorkspace = try container.decodeIfPresent(
            [String: ClaudeHookActiveSessionRecord].self,
            forKey: .activeSessionsByWorkspace
        ) ?? [:]
        activeSessionsBySurface = try container.decodeIfPresent(
            [String: ClaudeHookActiveSessionRecord].self,
            forKey: .activeSessionsBySurface
        ) ?? [:]
    }
}

struct AgentHookSessionActivationPolicy: Sendable {
    func canActivate(
        record: ClaudeHookSessionRecord,
        lineage: AgentHookSessionLineage,
        hasIncomingPID: Bool
    ) -> Bool {
        if !hasIncomingPID,
           let activeRunId = record.activeRunId,
           record.runs?.contains(where: {
               $0.runId == activeRunId
                   && $0.endedAt == nil
                   && $0.pid != nil
                   && $0.processStartedAt != nil
           }) == true {
            return false
        }
        if let activeRunId = record.activeRunId,
           activeRunId != lineage.runId,
           let activeRun = (record.runs ?? []).first(where: {
               $0.runId == activeRunId && $0.endedAt == nil
           }),
           let activeStartedAt = activeRun.processStartedAt,
           let incomingStartedAt = lineage.processStartedAt,
           incomingStartedAt + 0.001 < activeStartedAt {
            return false
        }
        guard record.completedAt != nil else { return true }
        // A completed record is a durable root-exit boundary. Only a hook that
        // supplies a verified, different process generation can reopen it.
        guard hasIncomingPID, let incomingStartedAt = lineage.processStartedAt else { return false }
        let matchingRuns = (record.runs ?? []).filter { $0.runId == lineage.runId }
        guard !matchingRuns.isEmpty else {
            guard let completedAt = record.completedAt else { return false }
            return incomingStartedAt > completedAt + 0.001
        }
        return matchingRuns.allSatisfy { run in
            guard let previousStartedAt = run.processStartedAt else { return false }
            return abs(previousStartedAt - incomingStartedAt) > 0.001
        }
    }
}

struct AgentSessionSemanticUpdatePolicy: Sendable {
    func canUpdate(record: ClaudeHookSessionRecord) -> Bool {
        record.completedAt == nil && record.sessionState != .ended
    }
}
