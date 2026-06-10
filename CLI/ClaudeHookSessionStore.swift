import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Claude hook session store
final class ClaudeHookSessionStore {
    private static let defaultStatePath = "~/.cmuxterm/claude-hook-sessions.json"
    private static let maxStateAgeSeconds: TimeInterval = 60 * 60 * 24 * 7
    private static let maxRememberedTerminalPromptTurnIds = 32

    private let statePath: String
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
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
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func lookup(sessionId: String) throws -> ClaudeHookSessionRecord? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState { state in
            state.sessions[normalized]
        }
    }

    func clearAgentLifecycleIfPresent(
        sessionId: String,
        workspaceId: String?,
        surfaceId: String?
    ) throws {
        let normalizedSessionId = normalizeSessionId(sessionId)
        guard !normalizedSessionId.isEmpty else { return }
        try withLockedState { state in
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
        updateRuntimeStatus: Bool = false
    ) throws -> Bool {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return false }
        return try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(
                state: state,
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            )
            update(
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
            )
            let normalizedTurnId = normalizeOptional(turnId)
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
                    return true
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
                    return totalDepth > 1
                }
                if turnStack.last == normalizedTurnId {
                    let totalDepth = max(legacyDepth, turnStack.count)
                    setActivePromptTurnStack(turnStack, totalDepth: totalDepth, on: &record)
                    record.lastPromptTurnId = normalizedTurnId
                    state.sessions[normalized] = record
                    return totalDepth > 1
                }
                let totalDepth = max(legacyDepth, turnStack.count) + 1
                turnStack.append(normalizedTurnId)
                setActivePromptTurnStack(turnStack, totalDepth: totalDepth, on: &record)
                record.lastPromptTurnId = normalizedTurnId
                state.sessions[normalized] = record
                return totalDepth > 1
            }
            let existingTurnStackDepth = activePromptTurnStack(from: record).count
            record.activePromptDepth = max(max(0, record.activePromptDepth ?? 0), existingTurnStackDepth) + 1
            state.sessions[normalized] = record
            return (record.activePromptDepth ?? 0) > 1
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
        updateRuntimeStatus: Bool = false
    ) throws -> Bool {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return false }
        return try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(
                state: state,
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            )
            let depthBeforeStop = max(0, record.activePromptDepth ?? 0)
            let depthAfterStop = max(0, depthBeforeStop - 1)
            update(
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
                now: now
            )
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
                        return nested
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
                    return true
                }
                if totalDepthBeforeStop == 0, terminalPromptTurnSet(from: record).contains(normalizedTurnId) {
                    state.sessions[normalized] = record
                    return true
                }
                markPromptTurnTerminal(normalizedTurnId, on: &record)
                if totalDepthBeforeStop == 0 {
                    state.sessions[normalized] = record
                    return false
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
                return totalDepthBeforeStop > 1
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
            return depthBeforeStop > 1
        }
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
        markActive: Bool = false,
        turnId: String? = nil,
        allowsNewSessionReplacement: Bool = false
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = state.sessions[normalized] ?? ClaudeHookSessionRecord(
                sessionId: normalized,
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
            update(
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
                now: now
            )
            state.sessions[normalized] = record
            if markActive, let normalizedWorkspace = normalizeOptional(workspaceId) {
                state.activeSessionsByWorkspace[normalizedWorkspace] = ClaudeHookActiveSessionRecord(
                    sessionId: normalized,
                    turnId: normalizeOptional(turnId),
                    allowsNewSessionReplacement: allowsNewSessionReplacement ? true : nil,
                    updatedAt: now
                )
            }
        }
    }

    func markNotificationResolved(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        pid: Int? = nil,
        launchCommand: AgentHookLaunchCommandRecord? = nil,
        agentLifecycle: AgentHibernationLifecycleState? = nil,
        runtimeStatus: AgentHookRuntimeStatus? = nil
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(
                state: state,
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            )
            update(
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
            )
            record.lastSubtitle = nil
            record.lastBody = nil
            record.lastNotificationStatus = nil
            state.sessions[normalized] = record
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
        record.terminalPromptTurnIds = terminalTurnIds.isEmpty ? nil : terminalTurnIds
    }

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
        now: TimeInterval
    ) {
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
            if incomingHasArguments || (incomingHasEnvironment && !existingHasArguments) {
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
        record.updatedAt = now
    }

    func clearNotificationEmission(sessionId: String) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            guard var record = state.sessions[normalized] else { return }
            let now = Date().timeIntervalSince1970
            record.lastEmittedNotificationFingerprint = nil
            record.lastEmittedNotificationAt = nil
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
        return try withLockedState { state in
            guard let record = state.sessions[normalized],
                  record.lastEmittedNotificationFingerprint == normalizedFingerprint,
                  let emittedAt = record.lastEmittedNotificationAt else {
                return false
            }
            return Date().timeIntervalSince1970 - emittedAt <= interval
        }
    }

    func markNotificationEmitted(sessionId: String, fingerprint: String) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        let normalizedFingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFingerprint.isEmpty else { return }
        try withLockedState { state in
            guard var record = state.sessions[normalized] else { return }
            let now = Date().timeIntervalSince1970
            record.lastEmittedNotificationFingerprint = normalizedFingerprint
            record.lastEmittedNotificationAt = now
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
        return try withLockedState { state in
            let excludedUpdatedAt = excluded.flatMap { state.sessions[$0]?.updatedAt }
            var foundRunningSession = false
            let now = Date().timeIntervalSince1970

            for sessionId in Array(state.sessions.keys) {
                guard var record = state.sessions[sessionId] else { continue }
                guard normalizeOptional(record.workspaceId) == normalizedWorkspace,
                      record.sessionId != excluded,
                      record.runtimeStatus == .running else {
                    continue
                }
                if let normalizedSurface, normalizeOptional(record.surfaceId) != normalizedSurface {
                    continue
                }
                if onlyNewerThanExcludedSession, let excludedUpdatedAt {
                    guard record.updatedAt > excludedUpdatedAt else {
                        continue
                    }
                }

                if requireLiveProcess, !Self.processExists(record.pid) {
                    record.runtimeStatus = nil
                    record.updatedAt = now
                    state.sessions[sessionId] = record
                    continue
                }

                foundRunningSession = true
                break
            }

            return foundRunningSession
        }
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
        turnId: String? = nil
    ) throws -> Bool {
        guard let normalizedSessionId = normalizeOptional(sessionId),
              let normalizedWorkspace = normalizeOptional(workspaceId) else {
            return true
        }
        return try withLockedState { state in
            guard let active = state.activeSessionsByWorkspace[normalizedWorkspace] else {
                return true
            }
            guard active.sessionId == normalizedSessionId else {
                return false
            }
            guard let activeTurnId = normalizeOptional(active.turnId),
                  let normalizedTurnId = normalizeOptional(turnId) else {
                return true
            }
            return activeTurnId == normalizedTurnId
        }
    }

    func canReplaceActiveSession(sessionId: String?, workspaceId: String) throws -> Bool {
        guard let normalizedSessionId = normalizeOptional(sessionId),
              let normalizedWorkspace = normalizeOptional(workspaceId) else {
            return false
        }
        return try withLockedState { state in
            guard let active = state.activeSessionsByWorkspace[normalizedWorkspace],
                  active.sessionId != normalizedSessionId else {
                return false
            }
            return active.allowsNewSessionReplacement == true
        }
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
        return try withLockedState { state in
            if let normalizedSessionId,
               let existing = state.sessions[normalizedSessionId] {
                guard !hasActiveTurnMismatch(state, record: existing, turnId: turnId) else {
                    return nil
                }
                let removed = state.sessions.removeValue(forKey: normalizedSessionId) ?? existing
                clearActiveSessionIfMatching(&state, removed: removed, turnId: turnId)
                return removed
            }

            guard let fallback = fallbackRecord(
                sessions: Array(state.sessions.values),
                workspaceId: normalizedWorkspace,
                surfaceId: normalizedSurface
            ) else {
                return nil
            }
            guard !hasActiveTurnMismatch(state, record: fallback, turnId: turnId) else {
                return nil
            }
            state.sessions.removeValue(forKey: fallback.sessionId)
            clearActiveSessionIfMatching(&state, removed: fallback, turnId: turnId)
            return fallback
        }
    }

    private func hasActiveTurnMismatch(
        _ state: ClaudeHookSessionStoreFile,
        record: ClaudeHookSessionRecord,
        turnId: String?
    ) -> Bool {
        guard let workspaceId = normalizeOptional(record.workspaceId),
              let active = state.activeSessionsByWorkspace[workspaceId],
              active.sessionId == record.sessionId,
              let activeTurnId = normalizeOptional(active.turnId),
              let incomingTurnId = normalizeOptional(turnId) else {
            return false
        }
        return activeTurnId != incomingTurnId
    }

    private func clearActiveSessionIfMatching(
        _ state: inout ClaudeHookSessionStoreFile,
        removed: ClaudeHookSessionRecord,
        turnId: String?
    ) {
        guard let workspaceId = normalizeOptional(removed.workspaceId),
              let active = state.activeSessionsByWorkspace[workspaceId],
              active.sessionId == removed.sessionId else {
            return
        }
        if let activeTurnId = normalizeOptional(active.turnId),
           let incomingTurnId = normalizeOptional(turnId),
           activeTurnId != incomingTurnId {
            return
        }
        state.activeSessionsByWorkspace.removeValue(forKey: workspaceId)
    }

    private func fallbackRecord(
        sessions: [ClaudeHookSessionRecord],
        workspaceId: String?,
        surfaceId: String?
    ) -> ClaudeHookSessionRecord? {
        if let surfaceId {
            let matches = sessions.filter { $0.surfaceId == surfaceId }
            return matches.max(by: { $0.updatedAt < $1.updatedAt })
        }
        if let workspaceId {
            let matches = sessions.filter { $0.workspaceId == workspaceId }
            if matches.count == 1 {
                return matches[0]
            }
        }
        return nil
    }

    private func withLockedState<T>(_ body: (inout ClaudeHookSessionStoreFile) throws -> T) throws -> T {
        let lockPath = statePath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw CLIError(message: "Failed to open Claude hook state lock: \(lockPath)")
        }
        defer { Darwin.close(fd) }

        if flock(fd, LOCK_EX) != 0 {
            throw CLIError(message: "Failed to lock Claude hook state: \(lockPath)")
        }
        defer { _ = flock(fd, LOCK_UN) }

        var state = loadUnlocked()
        pruneExpired(&state)
        let result = try body(&state)
        try saveUnlocked(state)
        return result
    }

    private func loadUnlocked() -> ClaudeHookSessionStoreFile {
        guard fileManager.fileExists(atPath: statePath) else {
            return ClaudeHookSessionStoreFile()
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let decoded = try? decoder.decode(ClaudeHookSessionStoreFile.self, from: data) else {
            return ClaudeHookSessionStoreFile()
        }
        return decoded
    }

    private func saveUnlocked(_ state: ClaudeHookSessionStoreFile) throws {
        let stateURL = URL(fileURLWithPath: statePath)
        let parentURL = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func pruneExpired(_ state: inout ClaudeHookSessionStoreFile) {
        let now = Date().timeIntervalSince1970
        let cutoff = now - Self.maxStateAgeSeconds
        state.sessions = state.sessions.filter { _, record in
            record.updatedAt >= cutoff
        }
        state.activeSessionsByWorkspace = state.activeSessionsByWorkspace.filter { _, active in
            active.updatedAt >= cutoff && state.sessions[active.sessionId] != nil
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

