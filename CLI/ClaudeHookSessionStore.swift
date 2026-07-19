import Darwin
import Foundation

/// Durable provider hook-session state and its lifecycle transitions.
final class ClaudeHookSessionStore {
    private enum PromptStopPreparation {
        case apply(AgentHookSessionLineage)
        case completed(AgentPromptStopCompletionReason, clearedActiveBoundary: Bool)
        case rejected
    }

    private static let defaultStatePath = "~/.cmuxterm/claude-hook-sessions.json"
    private static let maxRunsPerSession = 128
    private static let maxRememberedTerminalPromptTurnIds = 32
    private static let maxAutoNameRecentMessages = 24
    private static let maxAutoNameMessageCharacters = 1_000

    let statePath: String
    let fileManager: FileManager
    let processEnv: [String: String]
    let agentName: String
    private let lineageResolver: AgentHookSessionLineageResolver
    private let decoder = JSONDecoder()

    private var registryBridge: AgentHookSessionRegistryBridge {
        AgentHookSessionRegistryBridge(
            provider: agentName,
            statePath: statePath,
            environment: processEnv,
            fileManager: fileManager
        )
    }

    init(
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        agentName: String = "claude",
        lineageResolver: AgentHookSessionLineageResolver = AgentHookSessionLineageResolver()
    ) {
        if let overridePath = processEnv["CMUX_CLAUDE_HOOK_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.statePath = NSString(string: overridePath).expandingTildeInPath
        } else if let overrideDirectory = processEnv["CMUX_AGENT_HOOK_STATE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !overrideDirectory.isEmpty {
            self.statePath = URL(fileURLWithPath: NSString(string: overrideDirectory).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
                .path
        } else {
            self.statePath = NSString(string: Self.defaultStatePath).expandingTildeInPath
        }
        self.fileManager = fileManager
        self.processEnv = processEnv
        self.agentName = agentName
        self.lineageResolver = lineageResolver
    }

    func lookup(sessionId: String) throws -> ClaudeHookSessionRecord? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try registryBridge.lookup(sessionID: normalized, decoder: decoder)
    }

    func projectedRestoreAuthority(sessionId: String) throws -> Bool? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withSessionSnapshot(sessionID: normalized) { record -> Bool? in
            guard let record else { return nil }
            return AgentSessionRunCanonicalizer().projectedRun(
                record: record,
                provider: agentName
            ).restoreAuthority
        }
    }

    func snapshot() -> ClaudeHookSessionStoreFile {
        withSnapshotState { $0 }
    }

    func reconcileSemanticState(
        sessionId: String,
        foregroundState: AgentForegroundState? = nil,
        attentionState: AgentAttentionState? = nil,
        workloads: [AgentWorkloadRecord]? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedSessionState(sessionID: normalized) { state in
            guard var record = state.sessions[normalized],
                  AgentSessionSemanticUpdatePolicy().canUpdate(record: record) else { return }
            if let foregroundState { record.foregroundState = foregroundState }
            if let attentionState { record.attentionState = attentionState }
            if let workloads {
                record.workloads = AgentSessionWorkloadReconciler().replacingActiveWorkloads(
                    record.workloads ?? [],
                    with: workloads,
                    now: now
                )
            }
            record.updatedAt = max(record.updatedAt, now)
            state.sessions[normalized] = record
        }
    }

    /// Records hook-observed runtime permission state without creating a
    /// session record that has not passed the normal session-start path.
    func updateLastPermissionMode(
        sessionId: String,
        permissionMode: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        let mode = permissionMode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !mode.isEmpty else { return }
        try withLockedSessionState(sessionID: normalized) { state in
            guard var record = state.sessions[normalized],
                  record.lastPermissionMode != mode else { return }
            record.lastPermissionMode = mode
            record.updatedAt = max(record.updatedAt, now)
            state.sessions[normalized] = record
        }
    }

    struct AutoNamingRecentMessagesSnapshot {
        var messages: [AutoNamingTranscriptMessage]
        var totalMessageCount: Int
    }

    func autoNamingRecentMessages(sessionId: String) throws -> [AutoNamingTranscriptMessage] {
        try autoNamingRecentMessagesSnapshot(sessionId: sessionId).messages
    }

    func autoNamingRecentMessagesSnapshot(sessionId: String) throws -> AutoNamingRecentMessagesSnapshot {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else {
            return AutoNamingRecentMessagesSnapshot(messages: [], totalMessageCount: 0)
        }
        return try withSessionSnapshot(sessionID: normalized) { record in
            let messages = record?.autoNameRecentMessages ?? []
            return AutoNamingRecentMessagesSnapshot(
                messages: messages,
                totalMessageCount: max(messages.count, record?.autoNameMessageSequence ?? 0)
            )
        }
    }

    struct AutoNamingBeginOutcome {
        var decision: AutoNamingThrottleDecision
        var lastTitle: String?
    }

    /// Atomically evaluates the auto-naming throttle for a session and, when
    /// the decision is to proceed, records the in-flight marker inside the
    /// same locked transaction so a concurrent Stop hook sees it and skips.
    /// When no session record exists yet (the auto-name hook can race the
    /// sync Stop hook's upsert), a minimal record is synthesized so the
    /// marker and baseline writes are never silently dropped.
    func beginAutoNaming(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        transcriptLineCount: Int,
        now: Date,
        engine: AutoNamingEngine
    ) throws -> AutoNamingBeginOutcome {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else {
            return AutoNamingBeginOutcome(decision: .skipShortTranscript, lastTitle: nil)
        }
        return try withLockedSessionState(
            sessionID: normalized,
            workspaceID: workspaceId,
            surfaceID: surfaceId
        ) { state in
            var record = state.sessions[normalized] ?? ClaudeHookSessionRecord(
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                startedAt: now.timeIntervalSince1970,
                updatedAt: now.timeIntervalSince1970
            )
            let snapshot = AutoNamingSessionSnapshot(
                lastTitle: record.autoNameLastTitle,
                lastLineCount: record.autoNameLastLineCount,
                lastNamedAt: record.autoNameLastNamedAt,
                inFlightAt: record.autoNameInFlightAt,
                lastAttemptAt: record.autoNameLastAttemptAt
            )
            let decision = engine.throttleDecision(
                snapshot: snapshot,
                transcriptLineCount: transcriptLineCount,
                now: now
            )
            switch decision {
            case .proceed:
                record.autoNameInFlightAt = now.timeIntervalSince1970
            case .reseedBaseline(let to):
                record.autoNameLastLineCount = to
            case .skipShortTranscript, .skipInFlight, .skipTooSoon, .skipInsufficientGrowth:
                break
            }
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalized] = record
            return AutoNamingBeginOutcome(decision: decision, lastTitle: snapshot.lastTitle)
        }
    }

    /// Records a completed naming pass. On a confirmed apply, the durable
    /// baseline (title, line count, timestamp) advances; on failure only the
    /// in-flight marker clears, so the next qualifying Stop retries.
    func finishAutoNaming(
        sessionId: String,
        appliedTitle: String?,
        baselineLineCount: Int?,
        now: Date
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedSessionState(sessionID: normalized) { state in
            guard var record = state.sessions[normalized] else { return }
            record.autoNameInFlightAt = nil
            // Stamp every completed pass (success or failure) so the throttle
            // enforces a cooldown before retrying a failing summarizer.
            record.autoNameLastAttemptAt = now.timeIntervalSince1970
            if let appliedTitle, let baselineLineCount {
                record.autoNameLastTitle = appliedTitle
                record.autoNameLastLineCount = baselineLineCount
                record.autoNameLastNamedAt = now.timeIntervalSince1970
            }
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalized] = record
        }
    }

    func clearAgentLifecycleIfPresent(
        sessionId: String,
        workspaceId: String?,
        surfaceId: String?
    ) throws {
        let normalizedSessionId = normalizeSessionId(sessionId)
        guard !normalizedSessionId.isEmpty else { return }
        try withLockedSessionState(
            sessionID: normalizedSessionId,
            workspaceID: workspaceId,
            surfaceID: surfaceId
        ) { state in
            guard var record = state.sessions[normalizedSessionId] else { return }
            record.agentLifecycle = .unknown
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalizedSessionId] = record
        }
    }

    @discardableResult
    func recordPromptSubmit(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        turnId: String? = nil,
        previousActivePromptTurnIsTerminal: Bool = false,
        terminalActivePromptTurnIds: Set<String> = [],
        pid: Int?,
        launchCommand: AgentHookLaunchCommandRecord?,
        agentLifecycle: AgentHibernationLifecycleState? = nil,
        runtimeStatus: AgentHookRuntimeStatus? = nil,
        updateRuntimeStatus: Bool = false,
        autoNameMessages: [AutoNamingTranscriptMessage] = [],
        rejectTerminalTurn: Bool = false
    ) throws -> AgentPromptSubmitResult {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return AgentPromptSubmitResult(accepted: false, staleTerminalTurn: false, nested: false) }
        return try withLockedSessionState(
            sessionID: normalized,
            workspaceID: workspaceId,
            surfaceID: surfaceId
        ) { state in
            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(
                state: state,
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            )
            let normalizedTurnId = normalizeOptional(turnId)
            if rejectTerminalTurn,
               let normalizedTurnId,
               terminalPromptTurnSet(from: record).contains(normalizedTurnId) {
                return AgentPromptSubmitResult(accepted: false, staleTerminalTurn: true, nested: false)
            }
            guard update(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                isRestorable: nil,
                agentLifecycle: agentLifecycle,
                lastSubtitle: nil,
                lastBody: nil,
                lastNotificationStatus: nil,
                updateLastNotificationStatus: false,
                runtimeStatus: runtimeStatus,
                updateRuntimeStatus: updateRuntimeStatus,
                now: now
            ) else { return AgentPromptSubmitResult(accepted: false, staleTerminalTurn: false, nested: false) }
            appendAutoNameMessages(autoNameMessages, to: &record)
            if let normalizedTurnId {
                markPromptTurnActive(normalizedTurnId, on: &record)
                var turnStack = activePromptTurnStack(from: record)
                let legacyDepth = max(0, record.activePromptDepth ?? 0)
                if turnStack.isEmpty, legacyDepth > 0 {
                    record.activePromptDepth = legacyDepth + 1
                    record.activePromptTurnId = nil
                    record.activePromptTurnIds = nil
                    record.lastPromptTurnId = normalizedTurnId
                    state.sessions[normalized] = record
                    return AgentPromptSubmitResult(accepted: true, staleTerminalTurn: false, nested: true)
                } else if let activeTurnId = turnStack.last,
                          activeTurnId != normalizedTurnId {
                    var removedTurnCount = 0
                    var removedTerminalTurnIds: [String] = []
                    if previousActivePromptTurnIsTerminal {
                        removedTerminalTurnIds.append(turnStack.removeLast())
                        removedTurnCount += 1
                        while let activeTurnId = turnStack.last,
                              terminalActivePromptTurnIds.contains(activeTurnId) {
                            removedTerminalTurnIds.append(turnStack.removeLast())
                            removedTurnCount += 1
                        }
                    }
                    let totalDepth = max(0, max(legacyDepth, turnStack.count + removedTurnCount) - removedTurnCount) + 1
                    turnStack.append(normalizedTurnId)
                    setActivePromptTurnStack(turnStack, totalDepth: totalDepth, on: &record)
                    markPromptTurnsTerminal(removedTerminalTurnIds, on: &record)
                    record.lastPromptTurnId = normalizedTurnId
                    state.sessions[normalized] = record
                    return AgentPromptSubmitResult(accepted: true, staleTerminalTurn: false, nested: totalDepth > 1)
                }
                if turnStack.last == normalizedTurnId {
                    let totalDepth = max(legacyDepth, turnStack.count)
                    setActivePromptTurnStack(turnStack, totalDepth: totalDepth, on: &record)
                    record.lastPromptTurnId = normalizedTurnId
                    state.sessions[normalized] = record
                    return AgentPromptSubmitResult(accepted: true, staleTerminalTurn: false, nested: totalDepth > 1)
                }
                let totalDepth = max(legacyDepth, turnStack.count) + 1
                turnStack.append(normalizedTurnId)
                setActivePromptTurnStack(turnStack, totalDepth: totalDepth, on: &record)
                record.lastPromptTurnId = normalizedTurnId
                state.sessions[normalized] = record
                return AgentPromptSubmitResult(accepted: true, staleTerminalTurn: false, nested: totalDepth > 1)
            }
            let existingTurnStackDepth = activePromptTurnStack(from: record).count
            record.activePromptDepth = max(max(0, record.activePromptDepth ?? 0), existingTurnStackDepth) + 1
            state.sessions[normalized] = record
            return AgentPromptSubmitResult(accepted: true, staleTerminalTurn: false, nested: (record.activePromptDepth ?? 0) > 1)
        }
    }
    @discardableResult
    func recordPromptStop(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        turnId: String? = nil,
        terminalActivePromptTurnIds: Set<String> = [],
        pid: Int?,
        launchCommand: AgentHookLaunchCommandRecord?,
        agentLifecycle: AgentHibernationLifecycleState? = nil,
        lastSubtitle: String?,
        lastBody: String?,
        lastNotificationStatus: AgentHookNotificationStatus? = nil,
        updateLastNotificationStatus: Bool = false,
        runtimeStatus: AgentHookRuntimeStatus? = nil,
        updateRuntimeStatus: Bool = false,
        hadPendingBackgroundWorkAtStop: Bool? = nil,
        autoNameMessages: [AutoNamingTranscriptMessage] = []
    ) throws -> AgentPromptStopResult {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return AgentPromptStopResult(accepted: false, nested: false) }
        return try withLockedSessionState(
            sessionID: normalized,
            workspaceID: workspaceId,
            surfaceID: surfaceId
        ) { state in
            let now = Date().timeIntervalSince1970
            let existingRecord = state.sessions[normalized]
            let allowsTerminalLaunchCompletion = promptStopIsRootBoundary(existingRecord)
                && !recordHasLiveBackgroundAuthority(
                    existingRecord,
                    incomingPendingBackgroundWork: hadPendingBackgroundWorkAtStop
                )
            let lineage: AgentHookSessionLineage
            switch preparePromptStop(
                in: &state,
                sessionId: normalized,
                pid: pid,
                allowsTerminalLaunchCompletion: allowsTerminalLaunchCompletion
            ) {
            case .apply(let preparedLineage):
                lineage = preparedLineage
            case .completed(let reason, let clearedActiveBoundary):
                return AgentPromptStopResult(
                    accepted: false,
                    nested: false,
                    completedGeneration: true,
                    completionReason: reason,
                    clearedActiveBoundary: clearedActiveBoundary
                )
            case .rejected:
                return AgentPromptStopResult(accepted: false, nested: false)
            }
            var record = makeSessionRecord(
                state: state,
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            )
            let depthBeforeStop = max(0, record.activePromptDepth ?? 0)
            let depthAfterStop = max(0, depthBeforeStop - 1)
            guard update(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                isRestorable: nil,
                agentLifecycle: depthAfterStop == 0 ? agentLifecycle : .running,
                lastSubtitle: lastSubtitle,
                lastBody: lastBody,
                lastNotificationStatus: lastNotificationStatus,
                updateLastNotificationStatus: updateLastNotificationStatus,
                runtimeStatus: runtimeStatus,
                updateRuntimeStatus: updateRuntimeStatus,
                hadPendingBackgroundWorkAtStop: hadPendingBackgroundWorkAtStop,
                now: now,
                preResolvedLineage: lineage
            ) else { return AgentPromptStopResult(accepted: false, nested: false) }
            appendAutoNameMessages(autoNameMessages, to: &record)
            let normalizedTurnId = normalizeOptional(turnId)
            if let normalizedTurnId {
                var turnStack = activePromptTurnStack(from: record)
                var totalDepthBeforeStop = max(depthBeforeStop, turnStack.count)
                let terminalTurnIdsToPrune = terminalActivePromptTurnIds.subtracting([normalizedTurnId])
                if !terminalTurnIdsToPrune.isEmpty {
                    var removedTerminalTurnIds: [String] = []
                    turnStack.removeAll { activeTurnId in
                        if terminalTurnIdsToPrune.contains(activeTurnId) {
                            removedTerminalTurnIds.append(activeTurnId)
                            return true
                        }
                        return false
                    }
                    if !removedTerminalTurnIds.isEmpty {
                        totalDepthBeforeStop = max(0, totalDepthBeforeStop - removedTerminalTurnIds.count)
                        setActivePromptTurnStack(turnStack, totalDepth: totalDepthBeforeStop, on: &record)
                        markPromptTurnsTerminal(removedTerminalTurnIds, on: &record)
                    }
                }
                if let lastTurnId = turnStack.last {
                    if lastTurnId == normalizedTurnId {
                        let nested = totalDepthBeforeStop > 1
                        turnStack.removeLast()
                        setActivePromptTurnStack(
                            turnStack,
                            totalDepth: max(0, totalDepthBeforeStop - 1),
                            on: &record
                        )
                        markPromptTurnTerminal(normalizedTurnId, on: &record)
                        state.sessions[normalized] = record
                        return AgentPromptStopResult(accepted: true, nested: nested)
                    }
                    if let staleIndex = turnStack.lastIndex(of: normalizedTurnId) {
                        turnStack.remove(at: staleIndex)
                        setActivePromptTurnStack(
                            turnStack,
                            totalDepth: max(0, totalDepthBeforeStop - 1),
                            on: &record
                        )
                        markPromptTurnTerminal(normalizedTurnId, on: &record)
                    } else if depthBeforeStop > turnStack.count {
                        setActivePromptTurnStack(
                            turnStack,
                            totalDepth: max(0, totalDepthBeforeStop - 1),
                            on: &record
                        )
                        markPromptTurnTerminal(normalizedTurnId, on: &record)
                    }
                    state.sessions[normalized] = record
                    return AgentPromptStopResult(accepted: true, nested: true)
                }
                if totalDepthBeforeStop == 0, terminalPromptTurnSet(from: record).contains(normalizedTurnId) {
                    state.sessions[normalized] = record
                    return AgentPromptStopResult(accepted: true, nested: true)
                }
                markPromptTurnTerminal(normalizedTurnId, on: &record)
                if totalDepthBeforeStop == 0 {
                    state.sessions[normalized] = record
                    return AgentPromptStopResult(accepted: true, nested: false)
                }
                let depthAfterTurnStop = max(0, totalDepthBeforeStop - 1)
                if depthAfterTurnStop == 0 {
                    record.activePromptDepth = nil
                } else {
                    record.activePromptDepth = depthAfterTurnStop
                }
                record.activePromptTurnId = nil
                record.activePromptTurnIds = nil
                state.sessions[normalized] = record
                return AgentPromptStopResult(accepted: true, nested: totalDepthBeforeStop > 1)
            }
            if depthAfterStop == 0 {
                record.activePromptDepth = nil
                record.activePromptTurnId = nil
                record.activePromptTurnIds = nil
            } else {
                let turnStack = activePromptTurnStack(from: record)
                if !turnStack.isEmpty {
                    setActivePromptTurnStack(
                        Array(turnStack.prefix(depthAfterStop)),
                        totalDepth: depthAfterStop,
                        on: &record
                    )
                } else {
                    record.activePromptDepth = depthAfterStop
                }
                if let normalizedTurnId, turnStack.isEmpty {
                    record.activePromptTurnId = normalizedTurnId
                    record.activePromptTurnIds = Array(repeating: normalizedTurnId, count: depthAfterStop)
                }
            }
            state.sessions[normalized] = record
            return AgentPromptStopResult(accepted: true, nested: depthBeforeStop > 1)
        }
    }

    private func preparePromptStop(
        in state: inout ClaudeHookSessionStoreFile,
        sessionId: String,
        pid: Int?,
        allowsTerminalLaunchCompletion: Bool
    ) -> PromptStopPreparation {
        let existingRecord = state.sessions[sessionId]
        let lineage = lineageResolver.resolve(
            agentName: agentName,
            sessionId: sessionId,
            pid: pid,
            environment: processEnv
        )
        switch AgentPromptStopLineagePolicy().decision(
            record: existingRecord,
            lineage: lineage,
            incomingPID: pid
        ) {
        case .apply:
            return .apply(lineage)
        case .completeRecordedGeneration(let reason):
            if reason == .terminalLaunch, !allowsTerminalLaunchCompletion {
                return .apply(lineage)
            }
            guard let existingRecord,
                  AgentSessionTeardownConsumptionPolicy().canConsume(record: existingRecord) else {
                return .rejected
            }
            let completed = completeSessionRecord(existingRecord)
            state.sessions[sessionId] = completed
            let clearedActiveBoundary = clearActiveSessionIfMatching(
                &state,
                removed: completed,
                turnId: nil
            )
            return .completed(reason, clearedActiveBoundary: clearedActiveBoundary)
        case .rejectStaleGeneration:
            return .rejected
        }
    }

    private func promptStopIsRootBoundary(_ record: ClaudeHookSessionRecord?) -> Bool {
        guard let record else { return true }
        let depth = max(
            max(0, record.activePromptDepth ?? 0),
            activePromptTurnStack(from: record).count
        )
        return depth <= 1
    }

    private func recordHasLiveBackgroundAuthority(
        _ record: ClaudeHookSessionRecord?,
        incomingPendingBackgroundWork: Bool?
    ) -> Bool {
        if let incomingPendingBackgroundWork {
            return incomingPendingBackgroundWork
        }
        return record?.hadPendingBackgroundWorkAtStop == true
            || record?.workloads?.contains(where: {
                $0.keepsSessionBusy && $0.phase.isActive
            }) == true
    }

    func upsert(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        pid: Int? = nil,
        launchCommand: AgentHookLaunchCommandRecord? = nil,
        isRestorable: Bool? = nil,
        agentLifecycle: AgentHibernationLifecycleState? = nil,
        lastSubtitle: String? = nil,
        lastBody: String? = nil,
        lastNotificationStatus: AgentHookNotificationStatus? = nil,
        updateLastNotificationStatus: Bool = false,
        runtimeStatus: AgentHookRuntimeStatus? = nil,
        updateRuntimeStatus: Bool = false,
        hadPendingBackgroundWorkAtStop: Bool? = nil,
        markActive: Bool = false,
        turnId: String? = nil,
        allowsNewSessionReplacement: Bool = false
    ) throws -> Bool {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return false }
        return try withLockedSessionState(
            sessionID: normalized,
            workspaceID: workspaceId,
            surfaceID: surfaceId
        ) { state in
            applyUpsert(
                in: &state,
                normalizedSessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                isRestorable: isRestorable,
                agentLifecycle: agentLifecycle,
                lastSubtitle: lastSubtitle,
                lastBody: lastBody,
                lastNotificationStatus: lastNotificationStatus,
                updateLastNotificationStatus: updateLastNotificationStatus,
                runtimeStatus: runtimeStatus,
                updateRuntimeStatus: updateRuntimeStatus,
                hadPendingBackgroundWorkAtStop: hadPendingBackgroundWorkAtStop,
                markActive: markActive,
                turnId: turnId,
                allowsNewSessionReplacement: allowsNewSessionReplacement,
                preResolvedLineage: nil,
                now: Date().timeIntervalSince1970
            )
        }
    }

    func upsertPromptStop(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        pid: Int? = nil,
        launchCommand: AgentHookLaunchCommandRecord? = nil,
        isRestorable: Bool? = nil,
        agentLifecycle: AgentHibernationLifecycleState? = nil,
        lastSubtitle: String? = nil,
        lastBody: String? = nil,
        lastNotificationStatus: AgentHookNotificationStatus? = nil,
        updateLastNotificationStatus: Bool = false,
        runtimeStatus: AgentHookRuntimeStatus? = nil,
        updateRuntimeStatus: Bool = false,
        hadPendingBackgroundWorkAtStop: Bool? = nil,
        markActive: Bool = false,
        turnId: String? = nil,
        allowsNewSessionReplacement: Bool = false
    ) throws -> AgentPromptStopResult {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else {
            return AgentPromptStopResult(accepted: false, nested: false)
        }
        return try withLockedSessionState(
            sessionID: normalized,
            workspaceID: workspaceId,
            surfaceID: surfaceId
        ) { state in
            let existingRecord = state.sessions[normalized]
            let allowsTerminalLaunchCompletion = promptStopIsRootBoundary(existingRecord)
                && !recordHasLiveBackgroundAuthority(
                    existingRecord,
                    incomingPendingBackgroundWork: hadPendingBackgroundWorkAtStop
                )
            let lineage: AgentHookSessionLineage
            switch preparePromptStop(
                in: &state,
                sessionId: normalized,
                pid: pid,
                allowsTerminalLaunchCompletion: allowsTerminalLaunchCompletion
            ) {
            case .apply(let preparedLineage):
                lineage = preparedLineage
            case .completed(let reason, let clearedActiveBoundary):
                return AgentPromptStopResult(
                    accepted: false,
                    nested: false,
                    completedGeneration: true,
                    completionReason: reason,
                    clearedActiveBoundary: clearedActiveBoundary
                )
            case .rejected:
                return AgentPromptStopResult(accepted: false, nested: false)
            }
            let accepted = applyUpsert(
                in: &state,
                normalizedSessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                isRestorable: isRestorable,
                agentLifecycle: agentLifecycle,
                lastSubtitle: lastSubtitle,
                lastBody: lastBody,
                lastNotificationStatus: lastNotificationStatus,
                updateLastNotificationStatus: updateLastNotificationStatus,
                runtimeStatus: runtimeStatus,
                updateRuntimeStatus: updateRuntimeStatus,
                hadPendingBackgroundWorkAtStop: hadPendingBackgroundWorkAtStop,
                markActive: markActive,
                turnId: turnId,
                allowsNewSessionReplacement: allowsNewSessionReplacement,
                preResolvedLineage: lineage,
                now: Date().timeIntervalSince1970
            )
            return AgentPromptStopResult(accepted: accepted, nested: false)
        }
    }

    private func applyUpsert(
        in state: inout ClaudeHookSessionStoreFile,
        normalizedSessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        pid: Int?,
        launchCommand: AgentHookLaunchCommandRecord?,
        isRestorable: Bool?,
        agentLifecycle: AgentHibernationLifecycleState?,
        lastSubtitle: String?,
        lastBody: String?,
        lastNotificationStatus: AgentHookNotificationStatus?,
        updateLastNotificationStatus: Bool,
        runtimeStatus: AgentHookRuntimeStatus?,
        updateRuntimeStatus: Bool,
        hadPendingBackgroundWorkAtStop: Bool?,
        markActive: Bool,
        turnId: String?,
        allowsNewSessionReplacement: Bool,
        preResolvedLineage: AgentHookSessionLineage?,
        now: TimeInterval
    ) -> Bool {
        var record = state.sessions[normalizedSessionId] ?? ClaudeHookSessionRecord(
            sessionId: normalizedSessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: nil,
            transcriptPath: nil,
            pid: nil,
            launchCommand: nil,
            isRestorable: nil,
            agentLifecycle: nil,
            lastSubtitle: nil,
            lastBody: nil,
            lastNotificationStatus: nil,
            lastEmittedNotificationFingerprint: nil,
            lastEmittedNotificationAt: nil,
            runtimeStatus: nil,
            activePromptDepth: nil,
            activePromptTurnId: nil,
            activePromptTurnIds: nil,
            lastPromptTurnId: nil,
            terminalPromptTurnIds: nil,
            startedAt: now,
            updatedAt: now
        )
        guard update(
            &record,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: cwd,
            transcriptPath: transcriptPath,
            pid: pid,
            launchCommand: launchCommand,
            isRestorable: isRestorable,
            agentLifecycle: agentLifecycle,
            lastSubtitle: lastSubtitle,
            lastBody: lastBody,
            lastNotificationStatus: lastNotificationStatus,
            updateLastNotificationStatus: updateLastNotificationStatus,
            runtimeStatus: runtimeStatus,
            updateRuntimeStatus: updateRuntimeStatus,
            hadPendingBackgroundWorkAtStop: hadPendingBackgroundWorkAtStop,
            now: now,
            preResolvedLineage: preResolvedLineage
        ) else { return false }
        state.sessions[normalizedSessionId] = record
        if markActive {
            let activeRecord = ClaudeHookActiveSessionRecord(
                sessionId: normalizedSessionId,
                turnId: normalizeOptional(turnId),
                allowsNewSessionReplacement: allowsNewSessionReplacement ? true : nil,
                updatedAt: now
            )
            if let normalizedWorkspace = normalizeOptional(workspaceId) {
                state.activeSessionsByWorkspace[normalizedWorkspace] = activeRecord
            }
            if let normalizedSurface = normalizeOptional(surfaceId) {
                state.activeSessionsBySurface[normalizedSurface] = activeRecord
            }
        }
        return true
    }

    @discardableResult
    func upsertCodexSessionStartIfFresh(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        pid: Int? = nil,
        launchCommand: AgentHookLaunchCommandRecord? = nil,
        agentLifecycle: AgentHibernationLifecycleState? = nil,
        runtimeStatus: AgentHookRuntimeStatus? = nil,
        updateRuntimeStatus: Bool = false
    ) throws -> Bool {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return false }
        return try withLockedSessionState(
            sessionID: normalized,
            workspaceID: workspaceId,
            surfaceID: surfaceId
        ) { state in
            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(
                state: state,
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            )
            if codexSessionStartIsStale(record, incomingPID: pid) {
                return false
            }
            clearCodexSessionStartTurnState(on: &record)
            guard update(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                isRestorable: nil,
                agentLifecycle: agentLifecycle,
                lastSubtitle: nil,
                lastBody: nil,
                lastNotificationStatus: nil,
                updateLastNotificationStatus: false,
                runtimeStatus: runtimeStatus,
                updateRuntimeStatus: updateRuntimeStatus,
                now: now
            ) else { return false }
            state.sessions[normalized] = record
            return true
        }
    }

    @discardableResult
    func upsertCodexPromptRunningIfFresh(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        turnId: String? = nil,
        pid: Int? = nil,
        launchCommand: AgentHookLaunchCommandRecord? = nil
    ) throws -> Bool {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return false }
        return try withLockedSessionState(
            sessionID: normalized,
            workspaceID: workspaceId,
            surfaceID: surfaceId
        ) { state in
            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(
                state: state,
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            )
            if let normalizedTurnId = normalizeOptional(turnId),
               terminalPromptTurnSet(from: record).contains(normalizedTurnId) {
                return false
            }
            guard update(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                isRestorable: nil,
                agentLifecycle: .running,
                lastSubtitle: nil,
                lastBody: nil,
                lastNotificationStatus: nil,
                updateLastNotificationStatus: false,
                runtimeStatus: .running,
                updateRuntimeStatus: true,
                now: now
            ) else { return false }
            state.sessions[normalized] = record
            return true
        }
    }

    func codexSessionStartIsStale(
        sessionId: String,
        incomingPID: Int?,
        includeTerminalPromptTurnIds: Bool = true
    ) throws -> Bool {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return false }
        return try withSessionSnapshot(sessionID: normalized) { record in
            guard let record else { return false }
            return codexSessionStartIsStale(
                record,
                incomingPID: incomingPID,
                includeTerminalPromptTurnIds: includeTerminalPromptTurnIds
            )
        }
    }

    func codexPromptTurnIsTerminal(sessionId: String, turnId: String?) throws -> Bool {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty, let normalizedTurnId = normalizeOptional(turnId) else { return false }
        return try withSessionSnapshot(sessionID: normalized) { record in
            guard let record else { return false }
            return terminalPromptTurnSet(from: record).contains(normalizedTurnId)
        }
    }

    @discardableResult func markNotificationResolved(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        pid: Int? = nil,
        launchCommand: AgentHookLaunchCommandRecord? = nil,
        agentLifecycle: AgentHibernationLifecycleState? = nil,
        runtimeStatus: AgentHookRuntimeStatus? = nil
    ) throws -> Bool {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return false }
        return try withLockedSessionState(
            sessionID: normalized,
            workspaceID: workspaceId,
            surfaceID: surfaceId
        ) { state in
            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(
                state: state,
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            )
            guard update(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                isRestorable: nil,
                agentLifecycle: agentLifecycle,
                lastSubtitle: nil,
                lastBody: nil,
                lastNotificationStatus: nil,
                updateLastNotificationStatus: true,
                runtimeStatus: runtimeStatus,
                updateRuntimeStatus: runtimeStatus != nil,
                now: now
            ) else { return false }
            record.lastSubtitle = nil; record.lastBody = nil; record.lastNotificationStatus = nil
            state.sessions[normalized] = record; return true
        }
    }

    private func makeSessionRecord(
        state: ClaudeHookSessionStoreFile,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        now: TimeInterval
    ) -> ClaudeHookSessionRecord {
        state.sessions[sessionId] ?? ClaudeHookSessionRecord(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: nil,
            transcriptPath: nil,
            pid: nil,
            launchCommand: nil,
            isRestorable: nil,
            agentLifecycle: nil,
            lastSubtitle: nil,
            lastBody: nil,
            lastNotificationStatus: nil,
            lastEmittedNotificationFingerprint: nil,
            lastEmittedNotificationAt: nil,
            runtimeStatus: nil,
            activePromptDepth: nil,
            activePromptTurnId: nil,
            activePromptTurnIds: nil,
            lastPromptTurnId: nil,
            terminalPromptTurnIds: nil,
            startedAt: now,
            updatedAt: now
        )
    }

    private func activePromptTurnStack(from record: ClaudeHookSessionRecord) -> [String] {
        if let activePromptTurnIds = record.activePromptTurnIds {
            let normalized = activePromptTurnIds.compactMap { normalizeOptional($0) }
            if !normalized.isEmpty {
                return normalized
            }
        }
        if let activePromptTurnId = normalizeOptional(record.activePromptTurnId) {
            return [activePromptTurnId]
        }
        return []
    }

    private func setActivePromptTurnStack(_ stack: [String], totalDepth: Int? = nil, on record: inout ClaudeHookSessionRecord) {
        let normalizedStack = stack.compactMap { normalizeOptional($0) }
        let resolvedDepth = max(max(0, totalDepth ?? normalizedStack.count), normalizedStack.count)
        if resolvedDepth == 0 {
            record.activePromptDepth = nil
            record.activePromptTurnId = nil
            record.activePromptTurnIds = nil
        } else {
            record.activePromptDepth = resolvedDepth
            record.activePromptTurnId = normalizedStack.last
            record.activePromptTurnIds = normalizedStack.isEmpty ? nil : normalizedStack
        }
    }

    private func terminalPromptTurnStack(from record: ClaudeHookSessionRecord) -> [String] {
        record.terminalPromptTurnIds?.compactMap { normalizeOptional($0) } ?? []
    }

    private func terminalPromptTurnSet(from record: ClaudeHookSessionRecord) -> Set<String> {
        Set(terminalPromptTurnStack(from: record))
    }

    private func codexSessionStartIsStale(
        _ record: ClaudeHookSessionRecord,
        incomingPID: Int?,
        includeTerminalPromptTurnIds: Bool = true
    ) -> Bool {
        if max(record.activePromptDepth ?? 0, record.activePromptTurnIds?.count ?? 0) > 0 {
            // SessionStart is asynchronous. A late hook from the process that
            // owns the active turn must not erase that turn, but a resumed or
            // restored Codex process is a new generation and must be allowed to
            // replace state left behind when the previous TUI exited mid-turn.
            guard let incomingPID, let existingPID = record.pid else { return true }
            return incomingPID == existingPID
        }
        let hasCompletedTurnState = normalizeOptional(record.lastPromptTurnId) != nil
            || (includeTerminalPromptTurnIds && !terminalPromptTurnSet(from: record).isEmpty)
        guard hasCompletedTurnState,
              let incomingPID,
              let existingPID = record.pid else {
            return false
        }
        return incomingPID == existingPID
    }

    private func clearCodexSessionStartTurnState(on record: inout ClaudeHookSessionRecord) {
        record.activePromptDepth = nil
        record.activePromptTurnId = nil
        record.activePromptTurnIds = nil
        record.lastPromptTurnId = nil
    }

    private func markPromptTurnActive(_ turnId: String, on record: inout ClaudeHookSessionRecord) {
        var terminalTurnIds = terminalPromptTurnStack(from: record)
        terminalTurnIds.removeAll { $0 == turnId }
        record.terminalPromptTurnIds = terminalTurnIds.isEmpty ? nil : terminalTurnIds
    }

    private func markPromptTurnsTerminal(_ turnIds: [String], on record: inout ClaudeHookSessionRecord) {
        for turnId in turnIds {
            markPromptTurnTerminal(turnId, on: &record)
        }
    }

    private func markPromptTurnTerminal(_ turnId: String, on record: inout ClaudeHookSessionRecord) {
        guard let normalizedTurnId = normalizeOptional(turnId) else { return }
        var terminalTurnIds = terminalPromptTurnStack(from: record)
        terminalTurnIds.removeAll { $0 == normalizedTurnId }
        terminalTurnIds.append(normalizedTurnId)
        if terminalTurnIds.count > Self.maxRememberedTerminalPromptTurnIds {
            terminalTurnIds.removeFirst(terminalTurnIds.count - Self.maxRememberedTerminalPromptTurnIds)
        }
        record.lastPromptTurnId = normalizedTurnId
        record.terminalPromptTurnIds = terminalTurnIds.isEmpty ? nil : terminalTurnIds
    }

    private func appendAutoNameMessages(
        _ messages: [AutoNamingTranscriptMessage],
        to record: inout ClaudeHookSessionRecord
    ) {
        guard !messages.isEmpty else { return }
        var recent = record.autoNameRecentMessages ?? []
        var appendedCount = 0
        for message in messages {
            guard let normalized = normalizedAutoNameMessage(message) else { continue }
            if recent.last == normalized { continue }
            recent.append(normalized)
            appendedCount += 1
        }
        if recent.count > Self.maxAutoNameRecentMessages {
            recent.removeFirst(recent.count - Self.maxAutoNameRecentMessages)
        }
        record.autoNameRecentMessages = recent.isEmpty ? nil : recent
        if appendedCount > 0 {
            record.autoNameMessageSequence = (record.autoNameMessageSequence ?? 0) + appendedCount
        }
    }

    private func normalizedAutoNameMessage(_ message: AutoNamingTranscriptMessage) -> AutoNamingTranscriptMessage? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard role == "user" || role == "assistant" else { return nil }
        let text = autoNameNormalizedSingleLine(message.text)
        guard !text.isEmpty else { return nil }
        return AutoNamingTranscriptMessage(
            role: role,
            text: autoNameTruncate(text, maxLength: Self.maxAutoNameMessageCharacters)
        )
    }

    private func autoNameNormalizedSingleLine(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func autoNameTruncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
        return String(value[..<index]) + "…"
    }

    @discardableResult
    private func update(
        _ record: inout ClaudeHookSessionRecord,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        pid: Int?,
        launchCommand: AgentHookLaunchCommandRecord?,
        isRestorable: Bool?,
        agentLifecycle: AgentHibernationLifecycleState?,
        lastSubtitle: String?,
        lastBody: String?,
        lastNotificationStatus: AgentHookNotificationStatus?,
        updateLastNotificationStatus: Bool,
        runtimeStatus: AgentHookRuntimeStatus?,
        updateRuntimeStatus: Bool,
        hadPendingBackgroundWorkAtStop: Bool? = nil,
        now: TimeInterval,
        preResolvedLineage: AgentHookSessionLineage? = nil
    ) -> Bool {
        let lineage = preResolvedLineage ?? lineageResolver.resolve(
            agentName: agentName,
            sessionId: record.sessionId,
            pid: pid,
            environment: processEnv
        )
        let activationDecision = AgentHookSessionActivationPolicy().decision(
            record: record,
            lineage: lineage,
            hasIncomingPID: pid != nil
        )
        guard case let .activate(activationProof) = activationDecision else {
            return false
        }
        record.workspaceId = workspaceId
        if !surfaceId.isEmpty {
            record.surfaceId = surfaceId
        }
        if let cwd = normalizeOptional(cwd) {
            record.cwd = cwd
        }
        if let transcriptPath = normalizeOptional(transcriptPath) {
            record.transcriptPath = transcriptPath
        }
        if let pid {
            record.pid = pid
        }
        if let launchCommand {
            let existingHasArguments = !(record.launchCommand?.arguments.isEmpty ?? true)
            let incomingHasArguments = !launchCommand.arguments.isEmpty
            let incomingHasEnvironment = !(launchCommand.environment?.isEmpty ?? true)
            // Persist an argv-bearing record always. Persist an argv-less, env-only record (the
            // CODEX_HOME / CLAUDE_CONFIG_DIR fallback for a plain agent whose launch argv couldn't be
            // captured) only when we don't already hold an argv-bearing one — so the durable store
            // keeps the non-default home for the fork/resume path without ever downgrading a richer
            // earlier capture to an env-only stub.
            if incomingHasArguments || normalizeOptional(launchCommand.source)?.lowercased() == "rejected" || (normalizeOptional(launchCommand.source)?.lowercased() == "default" && !existingHasArguments && normalizeOptional(record.launchCommand?.environment?["CODEX_HOME"]) == nil) || (incomingHasEnvironment && !existingHasArguments) {
                record.launchCommand = launchCommand
            }
        }
        if let isRestorable {
            // Preserve sticky true: a later isRestorable=false must not clear
            // record.isRestorable=true from a transcript-backed event.
            record.isRestorable = isRestorable || record.isRestorable == true
        }
        if let agentLifecycle {
            record.agentLifecycle = agentLifecycle
        }
        if let subtitle = normalizeOptional(lastSubtitle) {
            record.lastSubtitle = subtitle
        }
        if let body = normalizeOptional(lastBody) {
            record.lastBody = body
        }
        if updateLastNotificationStatus {
            record.lastNotificationStatus = lastNotificationStatus
        }
        if updateRuntimeStatus {
            record.runtimeStatus = runtimeStatus
        }
        if let hadPendingBackgroundWorkAtStop {
            record.hadPendingBackgroundWorkAtStop = hadPendingBackgroundWorkAtStop
        }
        record.completedAt = nil
        record.cmuxRestoreAdoptionId = nil
        record.cmuxHibernationAttemptId = nil
        record.cmuxHibernatedAt = nil
        record.cmuxHibernationDetached = nil
        record.cmuxHibernationResumeAttemptId = nil
        record.cmuxHibernationResumeStartedAt = nil
        record.cmuxHibernationResumeFromAttemptId = nil
        record.sessionState = .active
        recordSessionRun(
            &record,
            lineage: lineage,
            activationProof: activationProof,
            now: now
        )
        record.updatedAt = now
        return true
    }

    private func recordSessionRun(
        _ record: inout ClaudeHookSessionRecord,
        lineage: AgentHookSessionLineage,
        activationProof: AgentHookSessionActivationProof,
        now: TimeInterval
    ) {
        var effectiveLineage = lineage
        effectiveLineage.hibernationResumeAttemptId = nil
        switch lineage.processLaunchMode {
        case .oneShot, .nonSession:
            // Utility and print/exec processes may publish hooks while they are
            // alive, but they never own an interactive conversation that cmux
            // may replay after hibernation or app restore.
            effectiveLineage.restoreAuthority = false
        case .unknown where lineage.processStartedAt != nil:
            // A live native process with an argv shape we do not understand is
            // not safe to replay unless the protected lifecycle transition
            // proved its exact cmux resume attempt, or a later duplicate hook
            // describes that same already-authoritative process generation.
            // This catches newly added one-shot provider flags without breaking
            // legacy hook payloads that carry no PID.
            switch activationProof {
            case .exactHibernationResumeAttempt(let attemptId)
                where lineage.hibernationResumeAttemptId == attemptId
                    && lineage.processDescribesAgent
                    && lineage.restoreAuthority:
                effectiveLineage.hibernationResumeAttemptId = attemptId
                break
            case .existingVerifiedResumeGeneration(let attemptId, let runId, let pid, let processStartedAt)
                where lineage.hibernationResumeAttemptId == attemptId
                    && lineage.runId == runId
                    && lineage.pid == pid
                    && lineage.processStartedAt.map {
                        abs($0 - processStartedAt) <= 0.001
                    } == true
                    && lineage.processDescribesAgent
                    && lineage.restoreAuthority:
                effectiveLineage.hibernationResumeAttemptId = attemptId
                break
            case .ordinary,
                 .exactHibernationResumeAttempt(_),
                 .existingVerifiedResumeGeneration(_, _, _, _):
                effectiveLineage.restoreAuthority = false
            }
        case .interactive, .unknown:
            break
        }
        let runs = AgentSessionRunReconciler(maximumRecords: Self.maxRunsPerSession).reconciling(
            record.runs ?? [],
            activeRunId: record.activeRunId,
            lineage: effectiveLineage,
            now: now
        )
        record.runs = runs
        record.activeRunId = effectiveLineage.runId
        record.runId = effectiveLineage.runId
        let activeRun = runs.first { $0.runId == effectiveLineage.runId }
        record.cmuxRuntime = activeRun?.cmuxRuntime
        record.parentRunId = activeRun?.parentRunId
        record.restoreAuthority = activeRun?.restoreAuthority ?? false
        record.parentSessionId = activeRun?.parentSessionId
        record.relationship = activeRun?.relationship
    }

    func clearNotificationEmission(sessionId: String) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedSessionState(sessionID: normalized) { state in
            guard var record = state.sessions[normalized] else { return }
            let now = Date().timeIntervalSince1970
            record.lastEmittedNotificationFingerprint = nil
            record.lastEmittedNotificationAt = nil
            record.recentEmittedNotificationFingerprints = nil
            record.updatedAt = now
            state.sessions[normalized] = record
        }
    }

    func recentlyEmittedNotification(
        sessionId: String,
        fingerprint: String,
        within interval: TimeInterval = 60 * 60
    ) throws -> Bool {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return false }
        let normalizedFingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFingerprint.isEmpty else { return false }
        return try withSessionSnapshot(sessionID: normalized) { record in
            guard let record else { return false }
            let now = Date().timeIntervalSince1970
            if let emittedAt = record.recentEmittedNotificationFingerprints?[normalizedFingerprint],
               now - emittedAt <= interval {
                return true
            }
            guard record.lastEmittedNotificationFingerprint == normalizedFingerprint,
                  let emittedAt = record.lastEmittedNotificationAt else {
                return false
            }
            return now - emittedAt <= interval
        }
    }

    func markNotificationEmitted(sessionId: String, fingerprint: String) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        let normalizedFingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFingerprint.isEmpty else { return }
        try withLockedSessionState(sessionID: normalized) { state in
            guard var record = state.sessions[normalized] else { return }
            let now = Date().timeIntervalSince1970
            record.lastEmittedNotificationFingerprint = normalizedFingerprint
            record.lastEmittedNotificationAt = now
            var recent = record.recentEmittedNotificationFingerprints ?? [:]
            recent[normalizedFingerprint] = now
            recent = recent.filter { now - $0.value <= 60 * 60 }
            if recent.count > 16 {
                let keep = recent.sorted { lhs, rhs in
                    if lhs.value == rhs.value { return lhs.key < rhs.key }
                    return lhs.value > rhs.value
                }.prefix(16)
                recent = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            record.recentEmittedNotificationFingerprints = recent.isEmpty ? nil : recent
            record.updatedAt = now
            state.sessions[normalized] = record
        }
    }

    func hasRunningSession(
        workspaceId: String,
        surfaceId: String?,
        excludingSessionId: String?,
        onlyNewerThanExcludedSession: Bool = false,
        requireLiveProcess: Bool = false
    ) throws -> Bool {
        guard let normalizedWorkspace = normalizeOptional(workspaceId) else {
            return false
        }
        let normalizedSurface = normalizeOptional(surfaceId)
        let excluded = normalizeOptional(excludingSessionId)
        let excludedUpdatedAt = try excluded.flatMap {
            try registryBridge.lookup(sessionID: $0, decoder: decoder)?.updatedAt
        }
        let candidates = try registryBridge.runningRecords(
            workspaceID: normalizedWorkspace,
            surfaceID: normalizedSurface,
            decoder: decoder
        )
        let canonicalizer = AgentSessionRunCanonicalizer()
        for candidate in candidates {
            guard candidate.sessionId != excluded else { continue }
            if onlyNewerThanExcludedSession, let excludedUpdatedAt,
               candidate.updatedAt <= excludedUpdatedAt {
                continue
            }
            guard requireLiveProcess else { return true }
            let observedRun = canonicalizer.projectedRun(record: candidate, provider: agentName)
            let processIsLive = if observedRun.processStartedAt != nil {
                lineageResolver.processState(
                    pid: candidate.pid,
                    expectedStartedAt: observedRun.processStartedAt
                ) == .alive
            } else {
                Self.processExists(candidate.pid)
            }
            if observedRun.pid == candidate.pid,
               processIsLive {
                return true
            }

            let observedPID = candidate.pid
            let observedRunID = observedRun.runId
            let observedProcessStartedAt = observedRun.processStartedAt
            try withLockedSessionState(
                sessionID: candidate.sessionId,
                workspaceID: candidate.workspaceId,
                surfaceID: candidate.surfaceId
            ) { state in
                guard var current = state.sessions[candidate.sessionId],
                      current.runtimeStatus == .running,
                      current.pid == observedPID else { return }
                let currentRun = canonicalizer.projectedRun(record: current, provider: agentName)
                guard currentRun.runId == observedRunID,
                      currentRun.pid == observedPID,
                      currentRun.processStartedAt == observedProcessStartedAt else { return }
                current.runtimeStatus = nil
                current.updatedAt = Date().timeIntervalSince1970
                state.sessions[candidate.sessionId] = current
            }
        }
        return false
    }

    private static func processExists(_ pid: Int?) -> Bool {
        guard let pid, pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    /// Returns true when an event belongs to the workspace's active Claude session.
    /// It fails open when the event cannot identify a session/workspace, when no
    /// active session is registered yet, or when either side lacks a turnId so
    /// multi-turn continuations can proceed after Stop clears the active turn.
    func isCurrent(
        sessionId: String?,
        workspaceId: String,
        surfaceId: String? = nil,
        turnId: String? = nil
    ) throws -> Bool {
        guard let normalizedSessionId = normalizeOptional(sessionId),
              let normalizedWorkspace = normalizeOptional(workspaceId) else {
            return true
        }
        var state = try registryBridge.activeContext(
            workspaceID: normalizedWorkspace,
            surfaceID: normalizeOptional(surfaceId),
            decoder: decoder
        )
        backfillSurfaceActiveSlots(&state)
        return {
            // The pane's own active boundary decides first: a hook is stale when a
            // DIFFERENT session was promoted in the SAME surface (post-/clear or
            // replaced-session races in one pane). This stays true even after a
            // sibling pane — e.g. a forked conversation in a split — later takes
            // the single workspace-active slot.
            // https://github.com/manaflow-ai/cmux/issues/5908
            if let normalizedSurfaceId = normalizeOptional(surfaceId),
               let surfaceActive = state.activeSessionsBySurface[normalizedSurfaceId] {
                guard surfaceActive.sessionId == normalizedSessionId else {
                    return false
                }
                guard let activeTurnId = normalizeOptional(surfaceActive.turnId),
                      let normalizedTurnId = normalizeOptional(turnId) else {
                    return true
                }
                return activeTurnId == normalizedTurnId
            }
            guard let active = state.activeSessionsByWorkspace[normalizedWorkspace] else {
                return true
            }
            guard active.sessionId == normalizedSessionId else {
                // Legacy fallback for stores written before per-surface tracking:
                // a different active session only makes this hook stale when that
                // session lives in the SAME surface; concurrent sessions in
                // sibling panes stay current for their own surface.
                guard let normalizedSurfaceId = normalizeOptional(surfaceId),
                      let activeRecord = state.sessions[active.sessionId],
                      let activeSurfaceId = normalizeOptional(activeRecord.surfaceId) else {
                    // Cross-surface protection needs both surfaces; when the caller
                    // omits surfaceId or the active session's record is gone/surface-
                    // less, fall back to the stricter workspace-scoped staleness.
                    return false
                }
                return activeSurfaceId != normalizedSurfaceId
            }
            guard let activeTurnId = normalizeOptional(active.turnId),
                  let normalizedTurnId = normalizeOptional(turnId) else {
                return true
            }
            return activeTurnId == normalizedTurnId
        }()
    }

    func canReplaceActiveSession(
        sessionId: String?,
        workspaceId: String,
        surfaceId: String? = nil
    ) throws -> Bool {
        guard let normalizedSessionId = normalizeOptional(sessionId),
              let normalizedWorkspace = normalizeOptional(workspaceId) else {
            return false
        }
        var state = try registryBridge.activeContext(
            workspaceID: normalizedWorkspace,
            surfaceID: normalizeOptional(surfaceId),
            decoder: decoder
        )
        backfillSurfaceActiveSlots(&state)
        return {
            // Replacement is pane-scoped like staleness: a stopped session in
            // THIS surface allows its own pane to start a new session even when
            // another pane currently holds the workspace-active slot.
            // https://github.com/manaflow-ai/cmux/issues/5908
            if let normalizedSurfaceId = normalizeOptional(surfaceId),
               let surfaceActive = state.activeSessionsBySurface[normalizedSurfaceId] {
                guard surfaceActive.sessionId != normalizedSessionId else {
                    return false
                }
                return surfaceActive.allowsNewSessionReplacement == true
            }
            guard let active = state.activeSessionsByWorkspace[normalizedWorkspace],
                  active.sessionId != normalizedSessionId else {
                return false
            }
            return active.allowsNewSessionReplacement == true
        }()
    }

    func consume(
        sessionId: String?,
        workspaceId: String?,
        surfaceId: String?,
        turnId: String? = nil
    ) throws -> ClaudeHookSessionRecord? {
        let normalizedSessionId = normalizeOptional(sessionId)
        let normalizedWorkspace = normalizeOptional(workspaceId)
        let normalizedSurface = normalizeOptional(surfaceId)
        let exact = try normalizedSessionId.flatMap {
            try registryBridge.lookup(sessionID: $0, decoder: decoder)
        }
        let target: ClaudeHookSessionRecord
        if let exact {
            target = exact
        } else {
            let fallbacks = try registryBridge.fallbackRecords(
                workspaceID: normalizedWorkspace,
                surfaceID: normalizedSurface,
                decoder: decoder
            )
            if normalizedSurface != nil {
                guard let fallback = fallbacks.first else { return nil }
                target = fallback
            } else {
                guard fallbacks.count == 1, let fallback = fallbacks.first else { return nil }
                target = fallback
            }
        }
        return try withLockedSessionState(
            sessionID: target.sessionId,
            workspaceID: target.workspaceId,
            surfaceID: target.surfaceId
        ) { state in
            guard let existing = state.sessions[target.sessionId],
                  AgentSessionTeardownConsumptionPolicy().canConsume(record: existing) else {
                return nil
            }
            guard !hasActiveTurnMismatch(state, record: existing, turnId: turnId) else {
                return nil
            }
            let completed = completeSessionRecord(existing)
            state.sessions[target.sessionId] = completed
            clearActiveSessionIfMatching(&state, removed: completed, turnId: turnId)
            return completed
        }
    }


    private func hasActiveTurnMismatch(
        _ state: ClaudeHookSessionStoreFile,
        record: ClaudeHookSessionRecord,
        turnId: String?
    ) -> Bool {
        guard let incomingTurnId = normalizeOptional(turnId) else {
            return false
        }
        // Consult the pane-scoped slot alongside the workspace slot: once a
        // sibling pane takes the single workspace-active slot, only the
        // surface slot still proves that this session is mid-turn in its own
        // pane and a stale SessionEnd from an older turn must not consume it.
        // https://github.com/manaflow-ai/cmux/issues/5908
        var activeRecords: [ClaudeHookActiveSessionRecord] = []
        if let workspaceId = normalizeOptional(record.workspaceId),
           let active = state.activeSessionsByWorkspace[workspaceId] {
            activeRecords.append(active)
        }
        if let surfaceId = normalizeOptional(record.surfaceId),
           let active = state.activeSessionsBySurface[surfaceId] {
            activeRecords.append(active)
        }
        return activeRecords.contains { active in
            guard active.sessionId == record.sessionId,
                  let activeTurnId = normalizeOptional(active.turnId) else {
                return false
            }
            return activeTurnId != incomingTurnId
        }
    }

    @discardableResult
    private func clearActiveSessionIfMatching(
        _ state: inout ClaudeHookSessionStoreFile,
        removed: ClaudeHookSessionRecord,
        turnId: String?
    ) -> Bool {
        var cleared = false
        let incomingTurnId = normalizeOptional(turnId)
        func matches(_ active: ClaudeHookActiveSessionRecord) -> Bool {
            guard active.sessionId == removed.sessionId else { return false }
            if let activeTurnId = normalizeOptional(active.turnId),
               let incomingTurnId,
               activeTurnId != incomingTurnId {
                return false
            }
            return true
        }
        if let workspaceId = normalizeOptional(removed.workspaceId),
           let active = state.activeSessionsByWorkspace[workspaceId],
           matches(active) {
            state.activeSessionsByWorkspace.removeValue(forKey: workspaceId)
            cleared = true
        }
        for (surfaceId, active) in state.activeSessionsBySurface where matches(active) {
            state.activeSessionsBySurface.removeValue(forKey: surfaceId)
            cleared = true
        }
        return cleared
    }

    private func withLockedSessionState<T>(
        sessionID: String,
        workspaceID: String? = nil,
        surfaceID: String? = nil,
        _ body: (inout ClaudeHookSessionStoreFile) throws -> T
    ) throws -> T {
        try registryBridge.mutateSession(
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID
        ) { state in
            backfillSurfaceActiveSlots(&state)
            canonicalizeSessionRunsForMutation(&state, sessionID: sessionID)
            return try body(&state)
        }.result
    }

    private func canonicalizeSessionRunsForMutation(
        _ state: inout ClaudeHookSessionStoreFile,
        sessionID: String
    ) {
        guard var record = state.sessions[sessionID], record.runs?.isEmpty == false else { return }
        let canonicalizer = AgentSessionRunCanonicalizer()
        let runs = canonicalizer.runs(record: record, provider: agentName)
        let projectedRun = canonicalizer.projectedRun(
            canonicalRuns: runs,
            activeRunID: record.activeRunId
        )
        record.runs = runs
        record.runId = projectedRun.runId
        record.parentRunId = projectedRun.parentRunId
        record.parentSessionId = projectedRun.parentSessionId
        record.relationship = projectedRun.relationship
        record.restoreAuthority = projectedRun.restoreAuthority
        state.sessions[sessionID] = record
    }

    private func withSessionSnapshot<T>(
        sessionID: String,
        _ body: (ClaudeHookSessionRecord?) -> T
    ) throws -> T {
        try body(registryBridge.lookup(sessionID: sessionID, decoder: decoder))
    }

    /// Read-only hook decisions use an immutable file snapshot. Writers publish
    /// with an atomic rename, so readers observe either the complete previous
    /// state or the complete next state without joining the global writer lock.
    /// This keeps prompt hooks responsive when many cmux versions and agents
    /// share the durable history file. Pruning remains a writer responsibility.
    private func withSnapshotState<T>(_ body: (ClaudeHookSessionStoreFile) -> T) -> T {
        body(loadUnlocked())
    }

    private func loadUnlocked() -> ClaudeHookSessionStoreFile {
        var decoded = AgentHookSessionRegistryBridge(
            provider: agentName,
            statePath: statePath,
            environment: processEnv,
            fileManager: fileManager
        ).load(decoder: decoder)
        backfillSurfaceActiveSlots(&decoded)
        return decoded
    }

    /// Stores written before per-surface tracking (or rewritten by an older
    /// CLI, which drops the unknown key) carry only workspace-active slots.
    /// Rebuild the pane boundary from each workspace-active session's recorded
    /// surface so pre-upgrade panes keep suppressing stale hooks after a
    /// sibling pane takes the workspace slot.
    /// https://github.com/manaflow-ai/cmux/issues/5908
    private func backfillSurfaceActiveSlots(_ state: inout ClaudeHookSessionStoreFile) {
        guard state.activeSessionsBySurface.isEmpty else { return }
        for active in state.activeSessionsByWorkspace.values {
            guard let surfaceId = normalizeOptional(state.sessions[active.sessionId]?.surfaceId) else {
                continue
            }
            state.activeSessionsBySurface[surfaceId] = active
        }
    }

    private func normalizeSessionId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
