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
    var completedGeneration: Bool = false
    var completionReason: AgentPromptStopCompletionReason? = nil
    var clearedActiveBoundary: Bool = false

    var shouldClearVisibleState: Bool {
        guard completedGeneration, clearedActiveBoundary else { return false }
        return completionReason == .terminalLaunch || completionReason == .processExited
    }
}

enum AgentPromptStopCompletionReason: Sendable, Equatable {
    case terminalLaunch
    case processExited
    case processIdentityChanged
    case inconsistentRecord
}

enum AgentPromptStopLineageDecision: Sendable, Equatable {
    case apply
    case completeRecordedGeneration(AgentPromptStopCompletionReason)
    case rejectStaleGeneration
}

/// A Stop is a turn boundary for an already-observed process generation. It
/// may update that exact generation, or retire it once the kernel proves it is
/// gone. It must never create a replacement run from a dead or reused PID.
struct AgentPromptStopLineagePolicy: Sendable {
    func decision(
        record: ClaudeHookSessionRecord?,
        lineage: AgentHookSessionLineage,
        incomingPID: Int?
    ) -> AgentPromptStopLineageDecision {
        // A PID-less Stop carries no process-generation evidence. Applying it
        // can resurrect an ended record or mutate a newer generation that
        // reused the logical session id, so it fails closed.
        guard let incomingPID else { return .rejectStaleGeneration }
        guard let record else {
            guard lineage.processStartedAt != nil, lineage.processDescribesAgent else {
                return .rejectStaleGeneration
            }
            return liveGenerationDecision(lineage)
        }
        guard record.completedAt == nil, record.sessionState != .ended else {
            return .rejectStaleGeneration
        }

        if let activeRunId = record.activeRunId {
            let activeRuns = (record.runs ?? []).filter {
                $0.runId == activeRunId && $0.endedAt == nil
            }
            guard activeRuns.count <= 1 else {
                return .completeRecordedGeneration(.inconsistentRecord)
            }
            if let activeRun = activeRuns.first {
                if let activePID = activeRun.pid, activePID != incomingPID {
                    return .rejectStaleGeneration
                }
                guard let observedStartedAt = lineage.processStartedAt else {
                    return .completeRecordedGeneration(.processExited)
                }
                guard lineage.processDescribesAgent else {
                    return .completeRecordedGeneration(.processIdentityChanged)
                }
                if let expectedStartedAt = activeRun.processStartedAt {
                    guard abs(expectedStartedAt - observedStartedAt) <= 0.001 else {
                        return .completeRecordedGeneration(.processIdentityChanged)
                    }
                    return liveGenerationDecision(lineage)
                }
                // Legacy/runtime-fallback runs lack a start time. The live
                // process is the recorded generation only when it predates the
                // run's first hook observation. A later process proves reuse.
                guard observedStartedAt <= activeRun.startedAt + 0.001 else {
                    return .completeRecordedGeneration(.processIdentityChanged)
                }
                return liveGenerationDecision(lineage)
            }
        }

        if let recordedPID = record.pid {
            guard recordedPID == incomingPID else { return .rejectStaleGeneration }
            guard let observedStartedAt = lineage.processStartedAt else {
                return .completeRecordedGeneration(.processExited)
            }
            guard lineage.processDescribesAgent else {
                return .completeRecordedGeneration(.processIdentityChanged)
            }
            // Pre-run stores can migrate safely when the process predates the
            // immutable session creation boundary. A process born afterward is
            // a reuse of the saved numeric PID, not this session generation.
            guard observedStartedAt <= record.startedAt + 0.001 else {
                return .completeRecordedGeneration(.processIdentityChanged)
            }
            return liveGenerationDecision(lineage)
        }
        guard lineage.processStartedAt != nil, lineage.processDescribesAgent else {
            return .rejectStaleGeneration
        }
        return liveGenerationDecision(lineage)
    }

    private func liveGenerationDecision(
        _ lineage: AgentHookSessionLineage
    ) -> AgentPromptStopLineageDecision {
        lineage.processLaunchMode == .oneShot
            ? .completeRecordedGeneration(.terminalLaunch)
            : .apply
    }
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
            if let previousStartedAt = run.processStartedAt {
                return abs(previousStartedAt - incomingStartedAt) > 0.001
            }
            guard let completedAt = record.completedAt else { return false }
            return incomingStartedAt > completedAt + 0.001
        }
    }
}

struct AgentSessionTeardownConsumptionPolicy: Sendable {
    func canConsume(record: ClaudeHookSessionRecord) -> Bool {
        guard record.completedAt == nil else { return false }
        switch record.sessionState {
        case .ended, .hibernated, .restoring:
            return false
        case .active, nil:
            return true
        }
    }
}

struct AgentSessionSemanticUpdatePolicy: Sendable {
    func canUpdate(record: ClaudeHookSessionRecord) -> Bool {
        record.completedAt == nil && record.sessionState != .ended
    }
}
