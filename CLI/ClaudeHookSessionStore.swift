#if CMUX_CLI_TESTS
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif
#endif
import CMUXAgentLaunch
import Foundation
import CryptoKit
import Darwin

// Shared by the bundled CLI and cmuxTests. Keep store behavior in one source
// file so integration tests exercise the exact implementation shipped by the
// CLI rather than a test-only copy.
final class ClaudeHookSessionStore {
    private typealias CursorPendingShellApproval = ClaudeHookSessionRecord.PendingCursorShellApproval
    typealias CursorShellApprovalResolution = (
        matched: Bool,
        hasRemaining: Bool,
        expired: Bool,
        remainingDisplayCommand: String?,
        notificationCorrelationKeys: [String],
        remainingNotificationCorrelationKey: String?
    )
    typealias CursorShellApprovalRememberResult = (
        accepted: Bool,
        inserted: Bool,
        notificationCorrelationKey: String?,
        expiredNotificationCorrelationKeys: [String]
    )
    typealias CursorShellApprovalClearResult = (
        cleared: Bool,
        notificationCorrelationKeys: [String]
    )

    final class CursorShellApprovalReconciliationLease {
        private var fileDescriptor: Int32
        private let lockStart: off_t
        private let lockLength: off_t

        init(fileDescriptor: Int32, lockStart: off_t, lockLength: off_t) {
            self.fileDescriptor = fileDescriptor
            self.lockStart = lockStart
            self.lockLength = lockLength
        }

        func release() {
            guard fileDescriptor >= 0 else { return }
            var lock = flock(
                l_start: lockStart,
                l_len: lockLength,
                l_pid: 0,
                l_type: Int16(F_UNLCK),
                l_whence: Int16(SEEK_SET)
            )
            _ = Darwin.fcntl(fileDescriptor, F_SETLK, &lock)
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }

        deinit {
            release()
        }
    }
    private static let defaultStatePath = "~/.cmuxterm/claude-hook-sessions.json"
    private static let maxStateAgeSeconds: TimeInterval = 60 * 60 * 24 * 7
    private static let maxPendingCursorShellApprovals = 16
    private static let maxPendingCursorShellCommandLength = 64 * 1024
    private static let maxPendingCursorShellApprovalAgeSeconds: TimeInterval = 60 * 60
    private static let maxHookStateFileBytes = 8 * 1024 * 1024
    private static let maxRecoverableHookStateFileBytes = 64 * 1024 * 1024
    private static let maxRecoveredHookSessions = 512
    private static let maxRecentlyClearedCursorShellCommandFingerprints = 16
    private static let recentlyClearedCursorShellCommandAgeSeconds: TimeInterval = 10 * 60
    private static let maxPendingCursorApprovalIndexEntriesPerSurface = 256
    private static let maxRememberedTerminalPromptTurnIds = 32
    private static let maxAutoNameRecentMessages = 24
    private static let maxAutoNameMessageCharacters = 1_000
    static let maxAutoNameTitleReconciliationAttempts = 4

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

    func lookup(sessionId: String, deadline: Date? = nil) throws -> ClaudeHookSessionRecord? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState(deadline: deadline, persist: false) { state in
            state.sessions[normalized]
        }
    }

    /// Atomically reserves the detached-worker spawn for one session.
    @discardableResult
    func claimAutoNamingSpawn(
        sessionId: String,
        workspaceId: String? = nil,
        surfaceId: String? = nil,
        now: Date
    ) throws -> String? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState { state in
            let timestamp = now.timeIntervalSince1970
            var record = state.sessions[normalized] ?? ClaudeHookSessionRecord(
                sessionId: normalized,
                workspaceId: workspaceId ?? "",
                surfaceId: surfaceId ?? "",
                startedAt: timestamp,
                updatedAt: timestamp
            )
            if let leaseAt = record.autoNameSpawnLeaseAt,
               timestamp - leaseAt < AutoNamingEngine().config.inFlightExpiry {
                return nil
            }
            if let inFlightAt = record.autoNameInFlightAt,
               timestamp - inFlightAt < AutoNamingEngine().config.inFlightExpiry {
                return nil
            }
            let token = UUID().uuidString
            record.autoNameSpawnLeaseAt = timestamp
            record.autoNameSpawnLeaseToken = token
            record.updatedAt = timestamp
            state.sessions[normalized] = record
            return token
        }
    }

    /// Releases a detached-worker reservation when launch or early setup fails.
    func releaseAutoNamingSpawn(sessionId: String, token: String) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            guard var record = state.sessions[normalized],
                  record.autoNameSpawnLeaseToken == token else { return }
            record.autoNameSpawnLeaseAt = nil
            record.autoNameSpawnLeaseToken = nil
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalized] = record
        }
    }

    /// Records one Cursor shell command for atomic completion correlation.
    /// Cursor's after/failure hook payloads do not expose the native approval
    /// decision or a stable tool id, so the normalized command is the durable
    /// identity shared by the before and terminal hook callbacks.
    @discardableResult
    func rememberCursorShellApproval(
        sessionId: String,
        command: String,
        toolUseId: String? = nil,
        deadline: Date? = nil
    ) throws -> CursorShellApprovalRememberResult {
        let normalizedSession = normalizeSessionId(sessionId)
        guard !normalizedSession.isEmpty,
              let normalizedCommand = normalizedCursorShellCommand(command) else {
            return (
                accepted: false,
                inserted: false,
                notificationCorrelationKey: nil,
                expiredNotificationCorrelationKeys: []
            )
        }
        return try withLockedState(deadline: deadline) { state in
            guard var record = state.sessions[normalizedSession] else {
                return (
                    accepted: false,
                    inserted: false,
                    notificationCorrelationKey: nil,
                    expiredNotificationCorrelationKeys: []
                )
            }
            var pending = record.pendingCursorShellApprovals ?? []
            let now = Date().timeIntervalSince1970
            let hadUnexpiredPending = hasUnexpiredCursorShellApproval(record, now: now)
            let pendingCountBeforePrune = pending.count
            var recentlyCleared = (record.recentlyClearedCursorShellCommandFingerprints ?? [:]).filter {
                now - $0.value <= Self.recentlyClearedCursorShellCommandAgeSeconds
            }
            let expiredApprovals = pending.filter {
                now - $0.createdAt > Self.maxPendingCursorShellApprovalAgeSeconds
            }
            let expiredNotificationCorrelationKeys = expiredApprovals.compactMap(\.notificationCorrelationKey)
            for approval in expiredApprovals {
                recentlyCleared[approval.commandFingerprint] = now
            }
            if recentlyCleared.count > Self.maxRecentlyClearedCursorShellCommandFingerprints {
                record.cursorShellCommandOnlyCorrelationDisabled = true
            }
            if recentlyCleared.count > Self.maxRecentlyClearedCursorShellCommandFingerprints {
                recentlyCleared = Dictionary(
                    uniqueKeysWithValues: recentlyCleared.sorted { $0.value > $1.value }
                        .prefix(Self.maxRecentlyClearedCursorShellCommandFingerprints)
                        .map { ($0.key, $0.value) }
                )
            }
            let hadExpiredApprovals = !expiredApprovals.isEmpty
            pending.removeAll {
                now - $0.createdAt > Self.maxPendingCursorShellApprovalAgeSeconds
            }
            let normalizedToolUseId = normalizedCursorShellToolUseId(toolUseId)
            let commandIdentity = CursorPendingShellApproval.identity(for: normalizedCommand)
            let requiresToolUseId = record.cursorShellCommandOnlyCorrelationDisabled == true
                || recentlyCleared[commandIdentity.fingerprint].map {
                    now - $0 <= Self.recentlyClearedCursorShellCommandAgeSeconds
                } == true
            // Only a repeated stable tool id is a retry. Without one, two
            // identical commands may be concurrent invocations; preserving
            // both records lets two terminal callbacks consume both waits.
            let duplicateIndex = normalizedToolUseId.flatMap { toolUseId in
                pending.firstIndex { $0.toolUseId == toolUseId }
            }
            if let duplicateIndex {
                let existing = pending[duplicateIndex]
                if existing.commandFingerprint != commandIdentity.fingerprint
                    || existing.commandLength != commandIdentity.length {
                    pending[duplicateIndex] = CursorPendingShellApproval(
                        command: normalizedCommand,
                        toolUseId: normalizedToolUseId,
                        createdAt: existing.createdAt,
                        requiresToolUseId: existing.requiresToolUseId,
                        notificationCorrelationKey: existing.notificationCorrelationKey
                    )
                }
                if hadExpiredApprovals || pending.count != pendingCountBeforePrune
                    || existing.commandFingerprint != commandIdentity.fingerprint
                    || existing.commandLength != commandIdentity.length {
                    record.recentlyClearedCursorShellCommandFingerprints = recentlyCleared
                    record.pendingCursorShellApprovals = pending
                    record.updatedAt = now
                    state.sessions[normalizedSession] = record
                }
                addCursorPendingIndex(
                    &state,
                    sessionId: normalizedSession,
                    workspaceId: record.workspaceId,
                    surfaceId: record.surfaceId,
                    countDelta: hadUnexpiredPending || pending.isEmpty ? 0 : 1
                )
                return (
                    accepted: true,
                    inserted: false,
                    notificationCorrelationKey: pending[duplicateIndex].notificationCorrelationKey,
                    expiredNotificationCorrelationKeys: expiredNotificationCorrelationKeys
                )
            }
            guard pending.count < Self.maxPendingCursorShellApprovals else {
                if hadExpiredApprovals {
                    record.recentlyClearedCursorShellCommandFingerprints = recentlyCleared
                    record.pendingCursorShellApprovals = pending.isEmpty ? nil : pending
                    record.updatedAt = now
                    state.sessions[normalizedSession] = record
                    if pending.isEmpty, hadExpiredApprovals {
                        removeCursorPendingIndex(
                            &state,
                            sessionId: normalizedSession,
                            workspaceId: record.workspaceId,
                            surfaceId: record.surfaceId,
                            countDelta: -1
                        )
                    }
                }
                return (
                    accepted: false,
                    inserted: false,
                    notificationCorrelationKey: nil,
                    expiredNotificationCorrelationKeys: expiredNotificationCorrelationKeys
                )
            }
            pending.append(CursorPendingShellApproval(
                command: normalizedCommand,
                toolUseId: normalizedToolUseId,
                createdAt: now,
                requiresToolUseId: requiresToolUseId
            ))
            record.recentlyClearedCursorShellCommandFingerprints = recentlyCleared
            record.pendingCursorShellApprovals = pending
            record.updatedAt = now
            state.sessions[normalizedSession] = record
            addCursorPendingIndex(
                &state,
                sessionId: normalizedSession,
                workspaceId: record.workspaceId,
                surfaceId: record.surfaceId,
                countDelta: hadUnexpiredPending ? 0 : 1
            )
            return (
                accepted: true,
                inserted: true,
                notificationCorrelationKey: pending.last?.notificationCorrelationKey,
                expiredNotificationCorrelationKeys: expiredNotificationCorrelationKeys
            )
        }
    }

    /// Resolves exactly one pending Cursor shell command, rejecting unrelated
    /// or sandboxed completions without touching visible notification state.
    /// The compare-and-remove happens under the store lock so overlapping hook
    /// processes cannot clear one another's approval. Expired records are
    /// pruned on the next lifecycle callback; Cursor's current hook protocol
    /// exposes no independent deadline callback for a crashed process.
    @discardableResult
    func resolveCursorShellApproval(
        sessionId: String,
        command: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        pid: Int? = nil,
        launchCommand: AgentHookLaunchCommandRecord? = nil,
        toolUseId: String? = nil,
        hookEventName: String? = nil,
        deadline: Date? = nil,
        failureWasError: Bool = false
    ) throws -> CursorShellApprovalResolution {
        let normalizedSession = normalizeSessionId(sessionId)
        guard !normalizedSession.isEmpty,
              let normalizedCommand = normalizedCursorShellCommand(command) else {
            return (
                matched: false,
                hasRemaining: false,
                expired: false,
                remainingDisplayCommand: nil,
                notificationCorrelationKeys: [],
                remainingNotificationCorrelationKey: nil
            )
        }
        return try withLockedState(deadline: deadline) { state in
            guard var record = state.sessions[normalizedSession],
                  var pending = record.pendingCursorShellApprovals else {
                return (
                    matched: false,
                    hasRemaining: false,
                    expired: false,
                    remainingDisplayCommand: nil,
                    notificationCorrelationKeys: [],
                    remainingNotificationCorrelationKey: nil
                )
            }
            let now = Date().timeIntervalSince1970
            let beforePruneCount = pending.count
            let expiredApprovals = pending.filter {
                now - $0.createdAt > Self.maxPendingCursorShellApprovalAgeSeconds
            }
            let expiredNotificationCorrelationKeys = expiredApprovals.compactMap(\.notificationCorrelationKey)
            pending.removeAll {
                now - $0.createdAt > Self.maxPendingCursorShellApprovalAgeSeconds
            }
            let expired = pending.count != beforePruneCount
            if !expiredApprovals.isEmpty {
                var recentlyCleared = (record.recentlyClearedCursorShellCommandFingerprints ?? [:]).filter {
                    now - $0.value <= Self.recentlyClearedCursorShellCommandAgeSeconds
                }
                for approval in expiredApprovals {
                    recentlyCleared[approval.commandFingerprint] = now
                }
                if recentlyCleared.count > Self.maxRecentlyClearedCursorShellCommandFingerprints {
                    record.cursorShellCommandOnlyCorrelationDisabled = true
                    recentlyCleared = Dictionary(
                        uniqueKeysWithValues: recentlyCleared.sorted { $0.value > $1.value }
                            .prefix(Self.maxRecentlyClearedCursorShellCommandFingerprints)
                            .map { ($0.key, $0.value) }
                    )
                }
                record.recentlyClearedCursorShellCommandFingerprints = recentlyCleared
            }
            let normalizedToolUseId = normalizedCursorShellToolUseId(toolUseId)
            let commandIdentity = CursorPendingShellApproval.identity(for: normalizedCommand)
            guard let matchIndex = pending.firstIndex(where: { pendingApproval in
                if let normalizedToolUseId {
                    if let pendingToolUseId = pendingApproval.toolUseId {
                        return normalizedToolUseId == pendingToolUseId
                    }
                    return !pendingApproval.requiresToolUseId
                        && pendingApproval.commandFingerprint == commandIdentity.fingerprint
                        && pendingApproval.commandLength == commandIdentity.length
                }
                return !pendingApproval.requiresToolUseId
                    && pendingApproval.commandFingerprint == commandIdentity.fingerprint
                    && pendingApproval.commandLength == commandIdentity.length
            }) else {
                if expired {
                    record.pendingCursorShellApprovals = pending.isEmpty ? nil : pending
                    if pending.isEmpty {
                        record.agentLifecycle = .running
                        record.runtimeStatus = .running
                        record.lastNotificationStatus = nil
                        record.lastSubtitle = nil
                        record.lastBody = nil
                        removeCursorPendingIndex(
                            &state,
                            sessionId: normalizedSession,
                            workspaceId: record.workspaceId,
                            surfaceId: record.surfaceId,
                            countDelta: pending.isEmpty ? -1 : 0
                        )
                    } else {
                        addCursorPendingIndex(
                            &state,
                            sessionId: normalizedSession,
                            workspaceId: record.workspaceId,
                            surfaceId: record.surfaceId
                        )
                    }
                    state.sessions[normalizedSession] = record
                }
                return (
                    matched: false,
                    hasRemaining: !pending.isEmpty,
                    expired: expired,
                    remainingDisplayCommand: pending.last?.displayCommand,
                    notificationCorrelationKeys: expiredNotificationCorrelationKeys,
                    remainingNotificationCorrelationKey: pending.last?.notificationCorrelationKey
                )
            }
            let matchedNotificationCorrelationKey = pending[matchIndex].notificationCorrelationKey
            pending.remove(at: matchIndex)
            let hasRemaining = !pending.isEmpty
            let previousWorkspaceId = record.workspaceId
            let previousSurfaceId = record.surfaceId
            let lifecycle = failureWasError
                ? AgentHibernationLifecycleState.needsInput
                : (hasRemaining ? .needsInput : .running)
            let runtime = failureWasError
                ? AgentHookRuntimeStatus.error
                : (hasRemaining ? .needsInput : .running)
            let notificationStatus: AgentHookNotificationStatus? = failureWasError
                ? .error
                : (hasRemaining ? .needsInput : nil)
            update(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                isRestorable: nil,
                agentLifecycle: lifecycle,
                hookEventName: hookEventName,
                lastSubtitle: nil,
                lastBody: nil,
                lastNotificationStatus: notificationStatus,
                updateLastNotificationStatus: true,
                runtimeStatus: runtime,
                updateRuntimeStatus: true,
                now: now
            )
            record.pendingCursorShellApprovals = hasRemaining ? pending : nil
            let surfaceMoved = previousSurfaceId != record.surfaceId
            if surfaceMoved {
                removeCursorPendingIndex(
                    &state,
                    sessionId: normalizedSession,
                    workspaceId: previousWorkspaceId,
                    surfaceId: previousSurfaceId,
                    countDelta: -1
                )
            }
            if hasRemaining {
                addCursorPendingIndex(
                    &state,
                    sessionId: normalizedSession,
                    workspaceId: record.workspaceId,
                    surfaceId: record.surfaceId,
                    countDelta: surfaceMoved ? 1 : 0
                )
            } else if !surfaceMoved {
                removeCursorPendingIndex(
                    &state,
                    sessionId: normalizedSession,
                    workspaceId: record.workspaceId,
                    surfaceId: record.surfaceId,
                    countDelta: -1
                )
            }
            if hasRemaining {
                record.lastBody = pending.last?.displayCommand
            } else {
                record.lastSubtitle = nil
                record.lastBody = nil
                record.lastNotificationStatus = failureWasError ? .error : nil
            }
            state.sessions[normalizedSession] = record
            return (
                matched: true,
                hasRemaining: hasRemaining,
                expired: expired,
                remainingDisplayCommand: pending.last?.displayCommand,
                notificationCorrelationKeys: expiredNotificationCorrelationKeys
                    + [matchedNotificationCorrelationKey].compactMap { $0 },
                remainingNotificationCorrelationKey: pending.last?.notificationCorrelationKey
            )
        }
    }

    /// Drops all pending Cursor shell approvals when a session stops or starts
    /// a new turn, returning the exact notification identities that were
    /// visible for those approvals.
    @discardableResult
    func clearCursorShellApprovals(
        sessionId: String,
        deadline: Date? = nil
    ) throws -> CursorShellApprovalClearResult {
        let normalizedSession = normalizeSessionId(sessionId)
        guard !normalizedSession.isEmpty else {
            return (cleared: false, notificationCorrelationKeys: [])
        }
        return try withLockedState(deadline: deadline) { state in
            guard var record = state.sessions[normalizedSession],
                  record.pendingCursorShellApprovals?.isEmpty == false else {
                return (cleared: false, notificationCorrelationKeys: [])
            }
            let notificationCorrelationKeys = (record.pendingCursorShellApprovals ?? [])
                .compactMap(\.notificationCorrelationKey)
            let now = Date().timeIntervalSince1970
            var recentlyCleared = (record.recentlyClearedCursorShellCommandFingerprints ?? [:]).filter {
                now - $0.value <= Self.recentlyClearedCursorShellCommandAgeSeconds
            }
            for approval in record.pendingCursorShellApprovals ?? [] {
                recentlyCleared[approval.commandFingerprint] = now
            }
            if recentlyCleared.count > Self.maxRecentlyClearedCursorShellCommandFingerprints {
                record.cursorShellCommandOnlyCorrelationDisabled = true
                recentlyCleared = Dictionary(
                    uniqueKeysWithValues: recentlyCleared.sorted { $0.value > $1.value }
                        .prefix(Self.maxRecentlyClearedCursorShellCommandFingerprints)
                        .map { ($0.key, $0.value) }
                )
            }
            record.recentlyClearedCursorShellCommandFingerprints = recentlyCleared
            record.pendingCursorShellApprovals = nil
            removeCursorPendingIndex(
                &state,
                sessionId: normalizedSession,
                workspaceId: record.workspaceId,
                surfaceId: record.surfaceId,
                countDelta: -1
            )
            record.lastSubtitle = nil
            record.lastBody = nil
            record.lastNotificationStatus = nil
            record.updatedAt = now
            state.sessions[normalizedSession] = record
            return (cleared: true, notificationCorrelationKeys: notificationCorrelationKeys)
        }
    }

    /// Whether another Cursor approval remains pending on the same surface.
    /// Used to keep a late completion from clearing a newer session's wait.
    func hasPendingCursorShellApproval(
        workspaceId _: String,
        surfaceId: String,
        excludingSessionId: String?,
        deadline: Date? = nil
    ) throws -> Bool {
        let excluded = excludingSessionId.map(normalizeSessionId)
        return try withLockedState(deadline: deadline, persist: false) { state in
            let now = Date().timeIntervalSince1970
            let key = cursorPendingSurfaceKey(surfaceId: surfaceId)
            let indexed = state.pendingCursorApprovalSessionsBySurface[key] ?? []
            let indexedMatch = indexed.contains { candidate in
                guard let record = state.sessions[candidate],
                      hasUnexpiredCursorShellApproval(record, now: now),
                      cursorPendingSurfaceKey(surfaceId: record.surfaceId) == key else {
                    return false
                }
                return excluded.map { candidate != $0 } ?? true
            }
            if indexedMatch { return true }
            let totalCount = state.pendingCursorApprovalSessionCountsBySurface[key]
                ?? indexed.count
            let hiddenCount = max(0, totalCount - indexed.count)
            // When the capped id list overflowed, the exact count is the
            // bounded summary that preserves sibling detection. A count above
            // one proves that another session remains, even if the excluded
            // session is one of the omitted ids.
            if state.pendingCursorApprovalSurfaceOverflow[key] == true, hiddenCount > 0 {
                return true
            }
            if hiddenCount > 0, totalCount > 1 {
                return true
            }
            return false
        }
    }

    /// Pending approval ownership follows the globally stable surface id;
    /// workspace ids are transient while panes move between windows.
    private func cursorPendingSurfaceKey(surfaceId: String) -> String {
        surfaceId
    }

    private func hasUnexpiredCursorShellApproval(
        _ record: ClaudeHookSessionRecord,
        now: TimeInterval
    ) -> Bool {
        record.pendingCursorShellApprovals?.contains {
            now - $0.createdAt <= Self.maxPendingCursorShellApprovalAgeSeconds
        } == true
    }

    private func addCursorPendingIndex(
        _ state: inout ClaudeHookSessionStoreFile,
        sessionId: String,
        workspaceId _: String,
        surfaceId: String,
        countDelta: Int = 0
    ) {
        let key = cursorPendingSurfaceKey(surfaceId: surfaceId)
        var sessions = state.pendingCursorApprovalSessionsBySurface[key] ?? []
        if !sessions.contains(sessionId) {
            sessions.append(sessionId)
            if sessions.count > Self.maxPendingCursorApprovalIndexEntriesPerSurface {
                sessions.removeFirst(sessions.count - Self.maxPendingCursorApprovalIndexEntriesPerSurface)
            }
            state.pendingCursorApprovalSessionsBySurface[key] = sessions
        }
        if countDelta != 0 {
            let currentCount = state.pendingCursorApprovalSessionCountsBySurface[key]
                ?? max(0, sessions.count - (countDelta > 0 ? 1 : 0))
            let nextCount = max(0, currentCount + countDelta)
            state.pendingCursorApprovalSessionCountsBySurface[key] = nextCount
            if nextCount > Self.maxPendingCursorApprovalIndexEntriesPerSurface {
                state.pendingCursorApprovalSurfaceOverflow[key] = true
            }
        } else if state.pendingCursorApprovalSessionCountsBySurface[key] == nil {
            state.pendingCursorApprovalSessionCountsBySurface[key] = sessions.count
        }
        state.pendingCursorApprovalIndexInitialized = true
    }

    private func removeCursorPendingIndex(
        _ state: inout ClaudeHookSessionStoreFile,
        sessionId: String,
        workspaceId _: String,
        surfaceId: String,
        countDelta: Int = 0
    ) {
        let key = cursorPendingSurfaceKey(surfaceId: surfaceId)
        var sessions = state.pendingCursorApprovalSessionsBySurface[key] ?? []
        sessions.removeAll { $0 == sessionId }
        let currentCount = state.pendingCursorApprovalSessionCountsBySurface[key] ?? sessions.count
        let nextCount = max(0, currentCount + countDelta)
        if nextCount == 0 {
            state.pendingCursorApprovalSessionsBySurface.removeValue(forKey: key)
            state.pendingCursorApprovalSessionCountsBySurface.removeValue(forKey: key)
            state.pendingCursorApprovalSurfaceOverflow.removeValue(forKey: key)
        } else {
            state.pendingCursorApprovalSessionsBySurface[key] = sessions
            state.pendingCursorApprovalSessionCountsBySurface[key] = nextCount
            if nextCount > Self.maxPendingCursorApprovalIndexEntriesPerSurface {
                state.pendingCursorApprovalSurfaceOverflow[key] = true
            }
        }
        state.pendingCursorApprovalIndexInitialized = true
    }

    private func reconcileCursorPendingIndexAfterUpdate(
        _ state: inout ClaudeHookSessionStoreFile,
        sessionId: String,
        previousSurfaceId: String?,
        previousHadPending: Bool,
        record: ClaudeHookSessionRecord,
        now: TimeInterval
    ) {
        let surfaceMoved = previousSurfaceId != record.surfaceId
        if let previousSurfaceId, surfaceMoved {
            removeCursorPendingIndex(
                &state,
                sessionId: sessionId,
                workspaceId: "",
                surfaceId: previousSurfaceId,
                countDelta: -1
            )
        }
        if hasUnexpiredCursorShellApproval(record, now: now) {
            addCursorPendingIndex(
                &state,
                sessionId: sessionId,
                workspaceId: "",
                surfaceId: record.surfaceId,
                countDelta: surfaceMoved || !previousHadPending ? 1 : 0
            )
        } else if previousHadPending {
            removeCursorPendingIndex(
                &state,
                sessionId: sessionId,
                workspaceId: "",
                surfaceId: record.surfaceId,
                countDelta: -1
            )
        }
    }

    private func normalizedCursorShellCommand(_ command: String) -> String? {
        let normalized = command
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= Self.maxPendingCursorShellCommandLength else {
            return nil
        }
        return normalized
    }

    private func normalizedCursorShellToolUseId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256 else { return nil }
        return trimmed
    }

    /// Records the hook-observed permission mode on an existing session record.
    /// The already-current check happens INSIDE the lock: an unlocked pre-check
    /// can race an overlapping hook's write and skip persisting the newest mode,
    /// leaving restore on a stale (possibly more permissive) mode. Unknown
    /// sessions are left alone (the session-start upsert owns record creation).
    func updateLastPermissionMode(sessionId: String, permissionMode: String) throws {
        let normalized = normalizeSessionId(sessionId)
        let mode = permissionMode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !mode.isEmpty else { return }
        try withLockedState { state in
            guard var record = state.sessions[normalized],
                  record.lastPermissionMode != mode else { return }
            record.lastPermissionMode = mode
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
        return try withLockedState { state in
            let record = state.sessions[normalized]
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
        var observationGeneration: String?
        /// True when a transcript-shrink reconciliation has exhausted its
        /// bounded retry budget. Callers should suppress both socket replay
        /// and a fresh summarizer pass for this hook.
        var reconciliationExhausted: Bool = false
    }

    /// Atomically evaluates the auto-naming throttle and records the in-flight
    /// marker for reconciliation or an allowed naming pass. A disallowed pass
    /// does not claim an attempt, while transcript shrink can still reconcile.
    /// When no session record exists yet (the auto-name hook can race the
    /// sync Stop hook's upsert), a minimal record is synthesized so the
    /// in-flight reservation is never silently dropped.
    func beginAutoNaming(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        transcriptLineCount: Int,
        transcriptPath: String? = nil,
        now: Date,
        engine: AutoNamingEngine,
        allowNewTitleGeneration: Bool,
        spawnToken: String? = nil
    ) throws -> AutoNamingBeginOutcome {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else {
            return AutoNamingBeginOutcome(
                decision: .skipShortTranscript,
                lastTitle: nil,
                observationGeneration: nil,
                reconciliationExhausted: false
            )
        }
        return try withLockedState { state in
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
                lastObservedLineCount: max(
                    record.autoNameLastObservedLineCount ?? 0,
                    record.autoNameInFlightObservedLineCount ?? 0
                ),
                lastNamedAt: record.autoNameLastNamedAt,
                inFlightAt: record.autoNameInFlightAt,
                lastAttemptAt: record.autoNameLastAttemptAt
            )
            if let spawnToken {
                guard record.autoNameSpawnLeaseToken == spawnToken else {
                    return AutoNamingBeginOutcome(
                        decision: .skipInFlight,
                        lastTitle: snapshot.lastTitle,
                        observationGeneration: nil,
                        reconciliationExhausted: false
                    )
                }
                record.autoNameSpawnLeaseAt = nil
                record.autoNameSpawnLeaseToken = nil
            }
            if let transcriptPath = normalizeOptional(transcriptPath) {
                record.transcriptPath = transcriptPath
            }
            let decision = engine.throttleDecision(
                snapshot: snapshot,
                transcriptLineCount: transcriptLineCount,
                now: now
            )
            let isTranscriptReconciliation: Bool
            if case .reseedBaseline = decision {
                isTranscriptReconciliation = true
            } else {
                isTranscriptReconciliation = false
            }
            if isTranscriptReconciliation,
               record.autoNameTitleReconciliationGeneration == nil,
               max(0, record.autoNameTitleReconciliationAttemptCount ?? 0)
                    >= Self.maxAutoNameTitleReconciliationAttempts {
                // Ordinary shrink reconciliation has no explicit lifecycle
                // event that can identify a new epoch. Keep the terminal bound
                // until a fresh compact hook mints a new generation.
                return AutoNamingBeginOutcome(
                    decision: decision,
                    lastTitle: snapshot.lastTitle,
                    observationGeneration: nil,
                    reconciliationExhausted: true
                )
            }
            if isTranscriptReconciliation,
               record.autoNameTitleReconciliationEpochLineCount == nil {
                // Ordinary transcript-shrink reconciliation has no explicit
                // compact hook, so persist its first compacted progress marker
                // just like the durable Claude compact path.
                record.autoNameTitleReconciliationEpochLineCount = transcriptLineCount
                record.autoNameTitleReconciliationIsExplicit = false
            }
            let observationGeneration: String?
            switch decision {
            case .proceed where allowNewTitleGeneration, .reseedBaseline:
                observationGeneration = claimAutoNamingObservation(
                    transcriptLineCount,
                    record: &record
                )
                record.autoNameInFlightAt = now.timeIntervalSince1970
                if isTranscriptReconciliation {
                    record.autoNameTitleReconciliationAttemptCount = max(
                        0,
                        record.autoNameTitleReconciliationAttemptCount ?? 0
                    ) + 1
                }
            case .skipInFlight:
                observationGeneration = nil
                recordUnclaimedAutoNamingObservation(
                    transcriptLineCount,
                    joiningLiveClaim: true,
                    record: &record
                )
            case .proceed, .skipShortTranscript, .skipTooSoon, .skipInsufficientGrowth:
                observationGeneration = nil
                recordUnclaimedAutoNamingObservation(
                    transcriptLineCount,
                    joiningLiveClaim: false,
                    record: &record
                )
            }
            if !isTranscriptReconciliation,
               record.autoNameTitleReconciliationGeneration == nil {
                record.autoNameTitleReconciliationAttemptCount = nil
                record.autoNameTitleReconciliationEpochLineCount = nil
                record.autoNameTitleReconciliationIsExplicit = nil
            }
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalized] = record
            return AutoNamingBeginOutcome(
                decision: decision,
                lastTitle: snapshot.lastTitle,
                observationGeneration: observationGeneration,
                reconciliationExhausted: false
            )
        }
    }

    /// Starts a new in-flight observation claim. Any expired owner's accumulated
    /// observation first joins the stable high-water so a failed replacement
    /// cannot erase it.
    private func claimAutoNamingObservation(
        _ lineCount: Int?,
        record: inout ClaudeHookSessionRecord
    ) -> String {
        foldAutoNamingInFlightObservationIntoHighWater(record: &record)
        if let lineCount {
            record.autoNameLastObservedLineCount = max(
                lineCount,
                record.autoNameLastObservedLineCount ?? record.autoNameLastLineCount ?? 0
            )
        }
        let generation = UUID().uuidString
        record.autoNameLastObservationGeneration = generation
        record.autoNameInFlightObservedLineCount = lineCount
        return generation
    }

    /// Records a pass that did not claim work. A live in-flight owner consumes
    /// the observation; otherwise it advances the stable high-water directly.
    private func recordUnclaimedAutoNamingObservation(
        _ lineCount: Int,
        joiningLiveClaim: Bool,
        record: inout ClaudeHookSessionRecord
    ) {
        if joiningLiveClaim {
            if record.autoNameLastObservationGeneration != nil {
                record.autoNameInFlightObservedLineCount = max(
                    lineCount,
                    record.autoNameInFlightObservedLineCount ?? lineCount
                )
            } else {
                // Legacy stores can have a live marker without an ownership
                // token. Preserve its dedupe window and record conservatively.
                record.autoNameLastObservedLineCount = max(
                    lineCount,
                    record.autoNameLastObservedLineCount ?? record.autoNameLastLineCount ?? 0
                )
            }
            return
        }
        foldAutoNamingInFlightObservationIntoHighWater(record: &record)
        // A non-joining pass has already established that any old marker is
        // expired. Revoke it so a late finisher cannot mutate newer state.
        record.autoNameInFlightAt = nil
        record.autoNameLastObservationGeneration = nil
        record.autoNameInFlightObservedLineCount = nil
        record.autoNameLastObservedLineCount = max(
            lineCount,
            record.autoNameLastObservedLineCount ?? record.autoNameLastLineCount ?? 0
        )
    }

    private func foldAutoNamingInFlightObservationIntoHighWater(
        record: inout ClaudeHookSessionRecord
    ) {
        guard let inFlightObservedLineCount = record.autoNameInFlightObservedLineCount else { return }
        record.autoNameLastObservedLineCount = max(
            inFlightObservedLineCount,
            record.autoNameLastObservedLineCount ?? record.autoNameLastLineCount ?? 0
        )
    }

    private func autoNamingObservedHighWater(in record: ClaudeHookSessionRecord) -> Int {
        max(
            record.autoNameLastLineCount ?? 0,
            max(
                record.autoNameLastObservedLineCount ?? 0,
                record.autoNameInFlightObservedLineCount ?? 0
            )
        )
    }

    /// Advances the naming baseline for a settled pass that has no title to
    /// replay, such as a shrink after a title-less manual-ownership outcome.
    private func settleAutoNamingBaselineWithoutTitle(
        _ lineCount: Int,
        record: inout ClaudeHookSessionRecord
    ) {
        let reconciledLineCount = max(
            lineCount,
            record.autoNameInFlightObservedLineCount ?? lineCount
        )
        record.autoNameLastLineCount = reconciledLineCount
        // A transcript shrink establishes a new baseline. Retaining the
        // pre-compaction high-water would make every later Stop look like
        // another shrink until the transcript grows past the old size.
        record.autoNameLastObservedLineCount = reconciledLineCount
    }

    /// Records an explicit Claude compaction before any best-effort title
    /// replay. Duplicate delivery for the same progress epoch is reported as
    /// existing; a changed epoch mints a new generation. Returns nil when the
    /// session has neither a generated title nor a naming pass that can produce one.
    func markAutoNamingTitleReconciliationPending(
        sessionId: String,
        transcriptLineCount: Int? = nil
    ) throws -> (generation: String, isNew: Bool)? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState { state in
            guard var record = state.sessions[normalized],
                  record.autoNameLastTitle != nil || record.autoNameInFlightAt != nil else {
                return nil
            }
            let now = Date().timeIntervalSince1970
            let isSameReconciliationEpoch = transcriptLineCount == nil
                || record.autoNameTitleReconciliationEpochLineCount == transcriptLineCount
            if record.autoNameTitleReconciliationGeneration == nil,
               max(0, record.autoNameTitleReconciliationAttemptCount ?? 0)
                    >= Self.maxAutoNameTitleReconciliationAttempts,
               isSameReconciliationEpoch,
               record.autoNameTitleReconciliationIsExplicit == true {
                // The same explicit compact epoch already exhausted its
                // bounded retry budget. Ordinary shrink exhaustion is allowed
                // to mint a fresh explicit generation at the same line count.
                record.updatedAt = now
                state.sessions[normalized] = record
                return nil
            }
            if let existingGeneration = record.autoNameTitleReconciliationGeneration,
               transcriptLineCount == nil
                    || record.autoNameTitleReconciliationEpochLineCount == nil
                    || record.autoNameTitleReconciliationEpochLineCount == transcriptLineCount {
                // Duplicate compact delivery belongs to the same unresolved
                // obligation. Keep its generation and attempt budget intact;
                // only a later, cleared generation starts a new epoch.
                record.updatedAt = now
                state.sessions[normalized] = record
                return (generation: existingGeneration, isNew: false)
            }
            let generation = UUID().uuidString
            record.autoNameTitleReconciliationGeneration = generation
            record.autoNameTitleReconciliationEpochLineCount = transcriptLineCount
            record.autoNameTitleReconciliationAttemptCount = 0
            record.autoNameTitleReconciliationIsExplicit = true
            record.updatedAt = now
            state.sessions[normalized] = record
            return (generation: generation, isNew: true)
        }
    }

    /// Claims a pending title replay with the same in-flight marker used by
    /// regular naming. A pending-but-unclaimed result means another hook owns
    /// the replay and callers must skip normal throttle/LLM work.
    func claimPendingAutoNamingTitleReconciliation(
        sessionId: String,
        transcriptLineCount: Int?,
        now: Date,
        engine: AutoNamingEngine
    ) throws -> (
        pending: Bool,
        title: String?,
        compactedLineCount: Int?,
        generation: String?,
        observationGeneration: String?,
        exhausted: Bool
    ) {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return (false, nil, nil, nil, nil, false) }
        return try withLockedState { state in
            guard var record = state.sessions[normalized],
                  let generation = record.autoNameTitleReconciliationGeneration else {
                return (false, nil, nil, nil, nil, false)
            }
            let hasLiveInFlight = record.autoNameInFlightAt.map {
                now.timeIntervalSince1970 - $0 < engine.config.inFlightExpiry
            } ?? false
            let attemptCount = max(0, record.autoNameTitleReconciliationAttemptCount ?? 0)
            if !hasLiveInFlight,
               attemptCount >= Self.maxAutoNameTitleReconciliationAttempts {
                // Keep the normal title/baseline history intact, but abandon
                // this permanently unresolved compact obligation. Returning
                // `pending=true` with `exhausted=true` keeps the caller from
                // falling through into a fresh LLM pass on this Stop.
                record.autoNameTitleReconciliationGeneration = nil
                // Keep the maxed count as an exhausted marker. Without it,
                // the next Stop would reopen the same transcript-shrink
                // reconciliation through the ordinary path.
                record.autoNameLastObservationGeneration = nil
                record.autoNameInFlightObservedLineCount = nil
                record.autoNameInFlightAt = nil
                record.updatedAt = now.timeIntervalSince1970
                state.sessions[normalized] = record
                return (true, nil, nil, nil, nil, true)
            }
            let observedHighWater = autoNamingObservedHighWater(in: record)
            let compactedLineCount: Int? = transcriptLineCount.flatMap { current in
                guard observedHighWater > 0,
                      record.autoNameLastNamedAt != nil,
                      current < observedHighWater else { return nil }
                return current
            }
            guard let title = record.autoNameLastTitle else {
                if hasLiveInFlight {
                    if let transcriptLineCount {
                        recordUnclaimedAutoNamingObservation(
                            transcriptLineCount,
                            joiningLiveClaim: true,
                            record: &record
                        )
                    }
                    record.updatedAt = now.timeIntervalSince1970
                    state.sessions[normalized] = record
                    return (true, nil, nil, nil, nil, false)
                }
                if let transcriptLineCount {
                    recordUnclaimedAutoNamingObservation(
                        transcriptLineCount,
                        joiningLiveClaim: false,
                        record: &record
                    )
                    settleAutoNamingBaselineWithoutTitle(
                        transcriptLineCount,
                        record: &record
                    )
                }
                record.autoNameTitleReconciliationGeneration = nil
                record.autoNameTitleReconciliationEpochLineCount = nil
                record.autoNameTitleReconciliationAttemptCount = nil
                record.autoNameTitleReconciliationIsExplicit = nil
                record.autoNameInFlightAt = nil
                record.autoNameLastObservationGeneration = nil
                record.autoNameInFlightObservedLineCount = nil
                record.updatedAt = now.timeIntervalSince1970
                state.sessions[normalized] = record
                return (false, nil, nil, nil, nil, false)
            }
            if hasLiveInFlight {
                if let transcriptLineCount {
                    recordUnclaimedAutoNamingObservation(
                        transcriptLineCount,
                        joiningLiveClaim: true,
                        record: &record
                    )
                }
                record.updatedAt = now.timeIntervalSince1970
                state.sessions[normalized] = record
                return (true, nil, nil, nil, nil, false)
            }
            let observationGeneration = claimAutoNamingObservation(
                transcriptLineCount,
                record: &record
            )
            record.autoNameInFlightAt = now.timeIntervalSince1970
            record.autoNameTitleReconciliationAttemptCount = attemptCount + 1
            record.updatedAt = now.timeIntervalSince1970
            state.sessions[normalized] = record
            return (true, title, compactedLineCount, generation, observationGeneration, false)
        }
    }

    /// Completes a transcript-shrink reconciliation without changing normal
    /// naming cooldown or title history. A confirmed owner advances both the
    /// baseline and high-water through observations that joined while it ran.
    func finishAutoNamingReconciliation(
        sessionId: String,
        compactedLineCount: Int?,
        confirmedApply: Bool,
        baselineConfirmedWithoutTitle: Bool = false,
        claimedReconciliationGeneration: String? = nil,
        observationGeneration: String? = nil,
        clearPendingOnConfirmation: Bool = true
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            guard var record = state.sessions[normalized] else { return }
            guard let observationGeneration,
                  record.autoNameLastObservationGeneration == observationGeneration else {
                return
            }
            let ownsPendingGeneration = record.autoNameTitleReconciliationGeneration
                == claimedReconciliationGeneration
            if (confirmedApply || baselineConfirmedWithoutTitle), ownsPendingGeneration {
                if baselineConfirmedWithoutTitle, !confirmedApply,
                   let compactedLineCount {
                    settleAutoNamingBaselineWithoutTitle(
                        compactedLineCount,
                        record: &record
                    )
                } else if let compactedLineCount {
                    let reconciledLineCount = max(
                        compactedLineCount,
                        record.autoNameInFlightObservedLineCount ?? compactedLineCount
                    )
                    record.autoNameLastLineCount = reconciledLineCount
                    record.autoNameLastObservedLineCount = reconciledLineCount
                } else {
                    foldAutoNamingInFlightObservationIntoHighWater(record: &record)
                }
                if clearPendingOnConfirmation,
                   claimedReconciliationGeneration != nil {
                    record.autoNameTitleReconciliationGeneration = nil
                    record.autoNameTitleReconciliationEpochLineCount = nil
                    record.autoNameTitleReconciliationAttemptCount = nil
                    record.autoNameTitleReconciliationIsExplicit = nil
                } else if claimedReconciliationGeneration == nil {
                    // Ordinary transcript-shrink reconciliation has no
                    // durable generation, but a confirmed apply still resets
                    // its bounded retry budget for the next shrink.
                    record.autoNameTitleReconciliationAttemptCount = nil
                    record.autoNameTitleReconciliationEpochLineCount = nil
                    record.autoNameTitleReconciliationIsExplicit = nil
                }
            } else {
                foldAutoNamingInFlightObservationIntoHighWater(record: &record)
            }
            record.autoNameInFlightAt = nil
            record.autoNameLastObservationGeneration = nil
            record.autoNameInFlightObservedLineCount = nil
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalized] = record
        }
    }

    /// Records a completed naming pass. On a confirmed apply, the durable
    /// baseline (title, line count, timestamp) advances. Failure retains the
    /// observed high-water while releasing the owned claim for a later retry.
    func finishAutoNaming(
        sessionId: String,
        appliedTitle: String?,
        baselineLineCount: Int?,
        baselineConfirmedWithoutTitle: Bool = false,
        observationGeneration: String?,
        now: Date
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            guard var record = state.sessions[normalized] else { return }
            guard let observationGeneration,
                  record.autoNameLastObservationGeneration == observationGeneration else {
                return
            }
            let inFlightObservedLineCount = record.autoNameInFlightObservedLineCount
            foldAutoNamingInFlightObservationIntoHighWater(record: &record)
            record.autoNameInFlightAt = nil
            record.autoNameSpawnLeaseAt = nil
            record.autoNameLastObservationGeneration = nil
            record.autoNameInFlightObservedLineCount = nil
            // Stamp every completed pass (success or failure) so the throttle
            // enforces a cooldown before retrying a failing summarizer.
            record.autoNameLastAttemptAt = now.timeIntervalSince1970
            if let baselineLineCount {
                if let appliedTitle {
                    let isFirstConfirmedTitle = record.autoNameLastNamedAt == nil
                    record.autoNameLastTitle = appliedTitle
                    record.autoNameLastLineCount = baselineLineCount
                    record.autoNameLastNamedAt = now.timeIntervalSince1970
                    if isFirstConfirmedTitle,
                       let inFlightObservedLineCount {
                        // A failed first attempt may have observed a larger
                        // pre-compaction transcript. Once the first title is
                        // confirmed, discard that stale high-water while retaining
                        // observations that joined this owned attempt.
                        record.autoNameLastObservedLineCount = max(
                            baselineLineCount,
                            inFlightObservedLineCount
                        )
                    }
                } else if baselineConfirmedWithoutTitle {
                    record.autoNameLastLineCount = baselineLineCount
                    record.autoNameLastNamedAt = now.timeIntervalSince1970
                    record.autoNameLastObservedLineCount = max(
                        baselineLineCount,
                        record.autoNameLastObservedLineCount ?? baselineLineCount
                    )
                }
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
        hookEventName: String? = nil,
        runtimeStatus: AgentHookRuntimeStatus? = nil,
        updateRuntimeStatus: Bool = false,
        updateLastSummary: Bool = false,
        autoNameMessages: [AutoNamingTranscriptMessage] = [],
        rejectTerminalTurn: Bool = false
    ) throws -> (staleTerminalTurn: Bool, nested: Bool) {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return (staleTerminalTurn: false, nested: false) }
        return try withLockedState { state in
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
                return (staleTerminalTurn: true, nested: false)
            }
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
                hookEventName: hookEventName,
                lastSubtitle: nil,
                lastBody: nil,
                updateLastSummary: updateLastSummary,
                lastNotificationStatus: nil,
                updateLastNotificationStatus: false,
                runtimeStatus: runtimeStatus,
                updateRuntimeStatus: updateRuntimeStatus,
                now: now
            )
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
                    return (staleTerminalTurn: false, nested: true)
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
                    return (staleTerminalTurn: false, nested: totalDepth > 1)
                }
                if turnStack.last == normalizedTurnId {
                    let totalDepth = max(legacyDepth, turnStack.count)
                    setActivePromptTurnStack(turnStack, totalDepth: totalDepth, on: &record)
                    record.lastPromptTurnId = normalizedTurnId
                    state.sessions[normalized] = record
                    return (staleTerminalTurn: false, nested: totalDepth > 1)
                }
                let totalDepth = max(legacyDepth, turnStack.count) + 1
                turnStack.append(normalizedTurnId)
                setActivePromptTurnStack(turnStack, totalDepth: totalDepth, on: &record)
                record.lastPromptTurnId = normalizedTurnId
                state.sessions[normalized] = record
                return (staleTerminalTurn: false, nested: totalDepth > 1)
            }
            let existingTurnStackDepth = activePromptTurnStack(from: record).count
            record.activePromptDepth = max(max(0, record.activePromptDepth ?? 0), existingTurnStackDepth) + 1
            state.sessions[normalized] = record
            return (staleTerminalTurn: false, nested: (record.activePromptDepth ?? 0) > 1)
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
        hookEventName: String? = nil,
        lastSubtitle: String?,
        lastBody: String?,
        lastNotificationStatus: AgentHookNotificationStatus? = nil,
        updateLastNotificationStatus: Bool = false,
        runtimeStatus: AgentHookRuntimeStatus? = nil,
        updateRuntimeStatus: Bool = false,
        autoNameMessages: [AutoNamingTranscriptMessage] = []
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
                hookEventName: hookEventName,
                lastSubtitle: lastSubtitle,
                lastBody: lastBody,
                lastNotificationStatus: lastNotificationStatus,
                updateLastNotificationStatus: updateLastNotificationStatus,
                runtimeStatus: runtimeStatus,
                updateRuntimeStatus: updateRuntimeStatus,
                now: now
            )
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

    @discardableResult
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
        hookEventName: String? = nil,
        lastSubtitle: String? = nil,
        lastBody: String? = nil,
        /// When true, nil summary fields explicitly clear their persisted values.
        updateLastSummary: Bool = false,
        lastNotificationStatus: AgentHookNotificationStatus? = nil,
        updateLastNotificationStatus: Bool = false,
        runtimeStatus: AgentHookRuntimeStatus? = nil,
        updateRuntimeStatus: Bool = false,
        hadPendingBackgroundWorkAtStop: Bool? = nil,
        title: String? = nil,
        markActive: Bool = false,
        turnId: String? = nil,
        allowsNewSessionReplacement: Bool = false,
        supersedesSameProcessSession: Bool = false,
        deadline: Date? = nil
    ) throws -> [ClaudeHookSessionRecord] {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return [] }
        return try withLockedState(deadline: deadline) { state in
            let now = Date().timeIntervalSince1970
            let previousSurfaceId = state.sessions[normalized]?.surfaceId
            let previousHadPending = state.sessions[normalized].map {
                hasUnexpiredCursorShellApproval($0, now: now)
            } ?? false
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
                hookEventName: hookEventName,
                lastSubtitle: lastSubtitle,
                lastBody: lastBody,
                updateLastSummary: updateLastSummary,
                lastNotificationStatus: lastNotificationStatus,
                updateLastNotificationStatus: updateLastNotificationStatus,
                runtimeStatus: runtimeStatus,
                updateRuntimeStatus: updateRuntimeStatus,
                hadPendingBackgroundWorkAtStop: hadPendingBackgroundWorkAtStop,
                title: title,
                now: now
            )
            let superseded: [ClaudeHookSessionRecord]
            if supersedesSameProcessSession {
                superseded = supersededSessionCleanupCandidates(
                    in: &state,
                    keepingSessionId: normalized,
                    owner: record
                )
            } else {
                superseded = []
            }
            state.sessions[normalized] = record
            reconcileCursorPendingIndexAfterUpdate(
                &state,
                sessionId: normalized,
                previousSurfaceId: previousSurfaceId,
                previousHadPending: previousHadPending,
                record: record,
                now: now
            )
            if markActive {
                let activeRecord = ClaudeHookActiveSessionRecord(
                    sessionId: normalized,
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
            return superseded
        }
    }

    /// Atomically installs the identity reported by an authoritative Claude
    /// SessionStart on its owning surface. SessionStart is the first event that
    /// carries a fork or /clear child's real session id, so record creation and
    /// the active-surface boundary must be one locked transaction.
    ///
    /// A late startup/resume event from a session that is already known but no
    /// longer owns this surface is rejected unless the current owner explicitly
    /// allows replacement or the incoming process is demonstrably newer. This
    /// keeps /clear as an ordering barrier without treating a launch-time
    /// `--resume` argument as identity.
    @discardableResult
    func upsertAuthoritativeClaudeSessionStart(
        sessionId: String,
        source: String?,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        pid: Int? = nil,
        launchCommand: AgentHookLaunchCommandRecord? = nil,
        hookEventName: String? = nil,
        turnId: String? = nil
    ) throws -> Bool {
        let normalizedSessionId = normalizeSessionId(sessionId)
        guard !normalizedSessionId.isEmpty,
              let normalizedWorkspaceId = normalizeOptional(workspaceId),
              let normalizedSurfaceId = normalizeOptional(surfaceId) else {
            return false
        }
        return try withLockedState { state in
            let active = state.activeSessionsBySurface[normalizedSurfaceId]
            let existing = state.sessions[normalizedSessionId]
            let normalizedSource = normalizeOptional(source)?.lowercased()
            let replacesCurrentOwner = active?.sessionId != normalizedSessionId
            let acceptsReplacement = active?.allowsNewSessionReplacement == true
            let incomingProcessIsNewer = active
                .flatMap { state.sessions[$0.sessionId] }
                .map { authoritativeSessionStartProcessIsNewer(pid, than: $0) }
                ?? false
            let accepted = normalizedSource == "clear"
                || active == nil
                || !replacesCurrentOwner
                || existing == nil
                || acceptsReplacement
                || incomingProcessIsNewer
            guard accepted else { return false }

            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(
                state: state,
                sessionId: normalizedSessionId,
                workspaceId: normalizedWorkspaceId,
                surfaceId: normalizedSurfaceId,
                now: now
            )
            update(
                &record,
                workspaceId: normalizedWorkspaceId,
                surfaceId: normalizedSurfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                isRestorable: false,
                agentLifecycle: .running,
                hookEventName: hookEventName,
                lastSubtitle: nil,
                lastBody: nil,
                lastNotificationStatus: nil,
                updateLastNotificationStatus: false,
                runtimeStatus: nil,
                updateRuntimeStatus: false,
                now: now
            )
            state.sessions[normalizedSessionId] = record

            for (workspaceId, activeSession) in state.activeSessionsByWorkspace
                where workspaceId != normalizedWorkspaceId
                    && activeSession.sessionId == normalizedSessionId {
                state.activeSessionsByWorkspace.removeValue(forKey: workspaceId)
            }
            for (surfaceId, activeSession) in state.activeSessionsBySurface
                where surfaceId != normalizedSurfaceId
                    && activeSession.sessionId == normalizedSessionId {
                state.activeSessionsBySurface.removeValue(forKey: surfaceId)
            }
            let activeRecord = ClaudeHookActiveSessionRecord(
                sessionId: normalizedSessionId,
                turnId: normalizeOptional(turnId),
                allowsNewSessionReplacement: nil,
                updatedAt: now
            )
            state.activeSessionsByWorkspace[normalizedWorkspaceId] = activeRecord
            state.activeSessionsBySurface[normalizedSurfaceId] = activeRecord
            return true
        }
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
        hookEventName: String? = nil,
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
            if codexSessionStartIsStale(record, incomingPID: pid) {
                return false
            }
            clearCodexSessionStartTurnState(on: &record)
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
                hookEventName: hookEventName,
                lastSubtitle: nil,
                lastBody: nil,
                lastNotificationStatus: nil,
                updateLastNotificationStatus: false,
                runtimeStatus: runtimeStatus,
                updateRuntimeStatus: updateRuntimeStatus,
                now: now
            )
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
        launchCommand: AgentHookLaunchCommandRecord? = nil,
        hookEventName: String? = nil
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
            if let normalizedTurnId = normalizeOptional(turnId),
               terminalPromptTurnSet(from: record).contains(normalizedTurnId) {
                return false
            }
            update(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                isRestorable: nil,
                agentLifecycle: .running,
                hookEventName: hookEventName,
                lastSubtitle: nil,
                lastBody: nil,
                lastNotificationStatus: nil,
                updateLastNotificationStatus: false,
                runtimeStatus: .running,
                updateRuntimeStatus: true,
                now: now
            )
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
        return try withLockedState { state in
            guard let record = state.sessions[normalized] else { return false }
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
        return try withLockedState { state in
            guard let record = state.sessions[normalized] else { return false }
            return terminalPromptTurnSet(from: record).contains(normalizedTurnId)
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

    private func codexSessionStartIsStale(
        _ record: ClaudeHookSessionRecord,
        incomingPID: Int?,
        includeTerminalPromptTurnIds: Bool = true
    ) -> Bool {
        if max(record.activePromptDepth ?? 0, record.activePromptTurnIds?.count ?? 0) > 0 {
            return true
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
        hookEventName: String? = nil,
        lastSubtitle: String?,
        lastBody: String?,
        updateLastSummary: Bool = false,
        lastNotificationStatus: AgentHookNotificationStatus?,
        updateLastNotificationStatus: Bool,
        runtimeStatus: AgentHookRuntimeStatus?,
        updateRuntimeStatus: Bool,
        hadPendingBackgroundWorkAtStop: Bool? = nil,
        title: String? = nil,
        now: TimeInterval
    ) {
        record.workspaceId = workspaceId
        if !surfaceId.isEmpty {
            record.surfaceId = surfaceId
        }
        if let cwd = normalizeOptional(cwd) {
            record.cwd = cwd
        }
        if let title = normalizeOptional(title) {
            record.title = title
        }
        if let transcriptPath = normalizeOptional(transcriptPath) {
            record.transcriptPath = transcriptPath
        }
        if let pid {
            record.updateProcessGeneration(
                pid: pid,
                startIdentity: processStartIdentity(pid: pid)
            )
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
            } else if let verificationHome = normalizeOptional(launchCommand.verificationHome),
                      var existingLaunchCommand = record.launchCommand,
                      normalizeOptional(existingLaunchCommand.verificationHome) == nil {
                // Keep a richer argv capture while filling in the separate
                // Codex verification hint learned by a later hook event.
                existingLaunchCommand.verificationHome = verificationHome
                record.launchCommand = existingLaunchCommand
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
        if let hookEventName = normalizeOptional(hookEventName) {
            record.hookEventName = hookEventName
        }
        if updateLastSummary {
            record.lastSubtitle = normalizeOptional(lastSubtitle)
            record.lastBody = normalizeOptional(lastBody)
        } else {
            if let subtitle = normalizeOptional(lastSubtitle) {
                record.lastSubtitle = subtitle
            }
            if let body = normalizeOptional(lastBody) {
                record.lastBody = body
            }
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
        record.updatedAt = now
    }

    private func processStartIdentity(pid: Int) -> (seconds: Int64, microseconds: Int64)? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        return (
            seconds: Int64(info.pbi_start_tvsec),
            microseconds: Int64(info.pbi_start_tvusec)
        )
    }

    private func authoritativeSessionStartProcessIsNewer(
        _ incomingPID: Int?,
        than activeRecord: ClaudeHookSessionRecord
    ) -> Bool {
        guard let incomingPID,
              let incomingIdentity = processStartIdentity(pid: incomingPID) else {
            return false
        }
        if let seconds = activeRecord.pidStartSeconds,
           let microseconds = activeRecord.pidStartMicroseconds {
            return (incomingIdentity.seconds, incomingIdentity.microseconds) > (seconds, microseconds)
        }
        guard let activePID = activeRecord.pid,
              activePID != incomingPID else {
            return false
        }
        return !Self.processExists(activePID)
    }

    func clearNotificationEmission(sessionId: String) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            guard var record = state.sessions[normalized] else { return }
            let now = Date().timeIntervalSince1970
            record.lastEmittedNotificationFingerprint = nil
            record.lastEmittedNotificationAt = nil
            record.recentEmittedNotificationFingerprints = nil
            record.updatedAt = now
            state.sessions[normalized] = record
        }
    }

    /// Removes a provisional completion summary without changing the session's
    /// ownership or turn-depth state. A Codex Stop with live children is not a
    /// user-visible completion and must not be reused by a later notification.
    func clearNotificationSummary(sessionId: String) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            guard var record = state.sessions[normalized] else { return }
            record.lastSubtitle = nil
            record.lastBody = nil
            record.lastNotificationStatus = nil
            state.sessions[normalized] = record
        }
    }

    func recentlyEmittedNotification(
        sessionId: String,
        fingerprint: String,
        within interval: TimeInterval = 60 * 60,
        deadline: Date? = nil
    ) throws -> Bool {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return false }
        let normalizedFingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFingerprint.isEmpty else { return false }
        return try withLockedState(deadline: deadline) { state in
            guard let record = state.sessions[normalized] else { return false }
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

    func markNotificationEmitted(
        sessionId: String,
        fingerprint: String,
        deadline: Date? = nil
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        let normalizedFingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFingerprint.isEmpty else { return }
        try withLockedState(deadline: deadline) { state in
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
    func claimAgentHookFailureReport(
        agentName: String,
        stage: String,
        sessionId: String,
        within interval: TimeInterval = 15 * 60,
        deadline: Date? = nil
    ) throws -> Bool {
        let normalized = normalizeSessionId(sessionId)
        let key = "\(agentName):\(stage):\(normalized.isEmpty ? "unknown" : normalized)"
        return try withLockedState(deadline: deadline) { state in
            let now = Date().timeIntervalSince1970
            var reports = state.agentHookFailureReportTimestamps
            if let lastFailureAt = reports[key], now - lastFailureAt < interval {
                return false
            }
            reports[key] = now
            if reports.count > 64 {
                let newestReports = reports.sorted { $0.value > $1.value }.prefix(64)
                reports = Dictionary(uniqueKeysWithValues: newestReports.map { ($0.key, $0.value) })
            }
            state.agentHookFailureReportTimestamps = reports
            return true
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
            if onlyNewerThanExcludedSession, excludedUpdatedAt == nil { return false }
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
        surfaceId: String? = nil,
        turnId: String? = nil
    ) throws -> Bool {
        guard let normalizedSessionId = normalizeOptional(sessionId),
              let normalizedWorkspace = normalizeOptional(workspaceId) else {
            return true
        }
        return try withLockedState { state in
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
        }
    }

    /// Updates a compact continuation only when the identity observed before
    /// routing is still the owner of its pane. Compact hooks may arrive after a
    /// replacement session has taken the pane, so this compare-and-set keeps a
    /// stale event from rewriting the session's persisted workspace, surface,
    /// or process identity before the visible-mutation guard runs.
    @discardableResult
    func upsertCompactSessionIfCurrent(
        sessionId: String,
        expectedRecord: ClaudeHookSessionRecord?,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        pid: Int?,
        launchCommand: AgentHookLaunchCommandRecord?,
        targetIsAuthoritative: Bool
    ) throws -> Bool {
        let normalizedSessionId = normalizeSessionId(sessionId)
        guard !normalizedSessionId.isEmpty,
              let normalizedWorkspaceId = normalizeOptional(workspaceId),
              let normalizedSurfaceId = normalizeOptional(surfaceId) else {
            return false
        }
        return try withLockedState { state in
            let existing = state.sessions[normalizedSessionId]
            if let expectedRecord {
                guard let existing,
                      existing.workspaceId == expectedRecord.workspaceId,
                      existing.surfaceId == expectedRecord.surfaceId,
                      compactProcessIdentityMatches(
                          existing: existing,
                          expected: expectedRecord,
                          incomingPID: pid
                      ),
                      compactSessionStillOwnsTarget(
                          state: state,
                          record: existing,
                          targetWorkspaceId: normalizedWorkspaceId,
                          targetSurfaceId: normalizedSurfaceId,
                          targetIsAuthoritative: targetIsAuthoritative
                      ) else {
                    return false
                }
            } else {
                guard existing == nil,
                      targetIsAuthoritative,
                      compactTargetIsAvailable(
                          state: state,
                          sessionId: normalizedSessionId,
                          workspaceId: normalizedWorkspaceId,
                          surfaceId: normalizedSurfaceId
                      ) else {
                    return false
                }
            }

            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(
                state: state,
                sessionId: normalizedSessionId,
                workspaceId: normalizedWorkspaceId,
                surfaceId: normalizedSurfaceId,
                now: now
            )
            let inheritedActiveRecord: ClaudeHookActiveSessionRecord? = {
                let candidates = [
                    state.activeSessionsByWorkspace[normalizedWorkspaceId],
                    state.activeSessionsBySurface[normalizedSurfaceId],
                    state.activeSessionsByWorkspace[record.workspaceId],
                    state.activeSessionsBySurface[record.surfaceId],
                ]
                return candidates.compactMap { $0 }.first { $0.sessionId == normalizedSessionId }
            }()
            update(
                &record,
                workspaceId: normalizedWorkspaceId,
                surfaceId: normalizedSurfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                pid: pid,
                launchCommand: launchCommand,
                isRestorable: false,
                // Compact SessionStart continues the existing agent lifecycle;
                // unlike a fresh session, it must not overwrite running/idle/
                // needs-input state while only refreshing identity metadata.
                agentLifecycle: nil,
                lastSubtitle: nil,
                lastBody: nil,
                lastNotificationStatus: nil,
                updateLastNotificationStatus: false,
                runtimeStatus: nil,
                updateRuntimeStatus: false,
                now: now
            )
            state.sessions[normalizedSessionId] = record
            for (workspaceID, active) in state.activeSessionsByWorkspace
                where workspaceID != normalizedWorkspaceId && active.sessionId == normalizedSessionId {
                state.activeSessionsByWorkspace.removeValue(forKey: workspaceID)
            }
            for (surfaceID, active) in state.activeSessionsBySurface
                where surfaceID != normalizedSurfaceId && active.sessionId == normalizedSessionId {
                state.activeSessionsBySurface.removeValue(forKey: surfaceID)
            }
            let activeRecord = ClaudeHookActiveSessionRecord(
                sessionId: normalizedSessionId,
                turnId: inheritedActiveRecord?.turnId,
                allowsNewSessionReplacement: inheritedActiveRecord?.allowsNewSessionReplacement,
                updatedAt: now
            )
            if state.activeSessionsByWorkspace[normalizedWorkspaceId]?.sessionId == nil
                || state.activeSessionsByWorkspace[normalizedWorkspaceId]?.sessionId == normalizedSessionId {
                state.activeSessionsByWorkspace[normalizedWorkspaceId] = activeRecord
            }
            state.activeSessionsBySurface[normalizedSurfaceId] = activeRecord
            return true
        }
    }

    private func compactProcessIdentityMatches(
        existing: ClaudeHookSessionRecord,
        expected: ClaudeHookSessionRecord,
        incomingPID: Int?
    ) -> Bool {
        let expectedGeneration = expected.pidStartSeconds.flatMap { seconds in
            expected.pidStartMicroseconds.map { (seconds, $0) }
        }
        let existingGeneration = existing.pidStartSeconds.flatMap { seconds in
            existing.pidStartMicroseconds.map { (seconds, $0) }
        }
        if let expectedGeneration {
            guard let existingGeneration,
                  existingGeneration == expectedGeneration else { return false }
        } else if let expectedPID = expected.pid,
                  let existingPID = existing.pid,
                  expectedPID != existingPID {
            return false
        }
        if let incomingPID, let existingGeneration {
            guard let incomingIdentity = processStartIdentity(pid: incomingPID),
                  (incomingIdentity.seconds, incomingIdentity.microseconds) == existingGeneration else {
                return false
            }
        } else if let incomingPID,
                  let existingPID = existing.pid,
                  incomingPID != existingPID {
            return false
        }
        return true
    }

    private func compactSessionStillOwnsTarget(
        state: ClaudeHookSessionStoreFile,
        record: ClaudeHookSessionRecord,
        targetWorkspaceId: String,
        targetSurfaceId: String,
        targetIsAuthoritative: Bool
    ) -> Bool {
        let sessionId = record.sessionId
        let targetMatchesRecord = record.workspaceId == targetWorkspaceId
            && record.surfaceId == targetSurfaceId
        if let active = state.activeSessionsBySurface[record.surfaceId] {
            guard active.sessionId == sessionId else { return false }
        } else if targetMatchesRecord {
            guard state.activeSessionsByWorkspace[record.workspaceId]?.sessionId == sessionId else {
                // An exact-target compact without active ownership evidence is
                // a delayed event from an ended session, not a continuation.
                return false
            }
        }

        guard !targetMatchesRecord else { return true }
        guard targetIsAuthoritative else { return false }
        // A live pid/surface delivery resolution is the authoritative pane
        // owner during a move. The persisted active indexes still point at the
        // old record and are pruned before this transaction; requiring them to
        // prove the new target would make every target-only rehome impossible.
        // A workspace slot may belong to a sibling pane, so only a conflicting
        // surface owner can reject this pane-scoped authoritative target.
        return state.activeSessionsBySurface[targetSurfaceId]
            .map { $0.sessionId == sessionId } ?? true
    }

    private func compactTargetIsAvailable(
        state: ClaudeHookSessionStoreFile,
        sessionId: String,
        workspaceId: String,
        surfaceId: String
    ) -> Bool {
        if let active = state.activeSessionsBySurface[surfaceId], active.sessionId != sessionId {
            return false
        }
        if let active = state.activeSessionsByWorkspace[workspaceId],
           active.sessionId != sessionId,
           state.activeSessionsBySurface[surfaceId]?.sessionId != sessionId {
            return false
        }
        return true
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
        return try withLockedState { state in
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

    private func clearActiveSessionIfMatching(
        _ state: inout ClaudeHookSessionStoreFile,
        removed: ClaudeHookSessionRecord,
        turnId: String?
    ) {
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
        }
        for (surfaceId, active) in state.activeSessionsBySurface where matches(active) {
            state.activeSessionsBySurface.removeValue(forKey: surfaceId)
        }
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

    func withLockedState<T>(
        deadline: Date? = nil,
        persist: Bool = true,
        _ body: (inout ClaudeHookSessionStoreFile) throws -> T
    ) throws -> T {
        let lockPath = statePath + ".lock"
        // The lock file is opened before the state is ever saved, so the first
        // store access on a fresh HOME must create the state directory itself.
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: lockPath).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw CLIError(message: "Failed to open Claude hook state lock: \(lockPath)")
        }
        defer { Darwin.close(fd) }

        if let deadline {
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN, Date.now < deadline else {
                    throw CLIError(message: "Timed out locking Claude hook state: \(lockPath)")
                }
                usleep(5_000)
            }
        } else if flock(fd, LOCK_EX) != 0 {
            throw CLIError(message: "Failed to lock Claude hook state: \(lockPath)")
        }
        defer { _ = flock(fd, LOCK_UN) }

        if let deadline, Date.now >= deadline {
            throw CLIError(message: "Claude hook state deadline exceeded: \(lockPath)")
        }
        var state = try loadUnlocked(deadline: deadline)
        if let deadline, Date.now >= deadline {
            throw CLIError(message: "Claude hook state deadline exceeded: \(lockPath)")
        }
        pruneExpired(&state)
        let hasLegacyCursorPendingIndex = state.pendingCursorApprovalSessionsBySurface.keys.contains {
            $0.contains("|")
        }
        let hasUninitializedCursorPendingCounts = !state.pendingCursorApprovalSessionsBySurface.isEmpty
            && state.pendingCursorApprovalSessionCountsBySurface.isEmpty
        let hasUninitializedCursorPendingOverflow = state.pendingCursorApprovalSessionCountsBySurface.contains {
            $0.value > Self.maxPendingCursorApprovalIndexEntriesPerSurface
                && state.pendingCursorApprovalSurfaceOverflow[$0.key] != true
        }
        if !state.pendingCursorApprovalIndexInitialized
            || hasLegacyCursorPendingIndex
            || hasUninitializedCursorPendingCounts
            || hasUninitializedCursorPendingOverflow {
            reconcileCursorPendingIndex(&state)
            state.pendingCursorApprovalIndexInitialized = true
        }
        pruneCursorPendingIndex(&state)
        if let deadline, Date.now >= deadline {
            throw CLIError(message: "Claude hook state deadline exceeded: \(lockPath)")
        }
        let result = try body(&state)
        if let deadline, Date.now >= deadline {
            throw CLIError(message: "Claude hook state deadline exceeded: \(lockPath)")
        }
        if persist {
            try saveUnlocked(state, deadline: deadline)
        }
        return result
    }

    /// Acquires a surface-scoped ordering lease for Cursor approval state/UI.
    ///
    /// The state lock is released before socket I/O; this separate lease keeps
    /// approval creation, completion, and shared-status reconciliation ordered
    /// for one surface, so a sibling session cannot publish a newer wait
    /// between the pending check and its completion status update. When no
    /// surface is known, the session id remains the compatibility identity.
    /// The fixed shared lock file uses byte-range fcntl locks, so session count
    /// cannot create unbounded lock files. This lock is a cross-process
    /// ordering carve-out for synchronous hook callbacks; it guards only a
    /// short, bounded reconciliation section.
    func acquireCursorShellApprovalReconciliationLock(
        sessionId: String,
        surfaceId: String? = nil,
        deadline: Date? = nil
    ) throws -> CursorShellApprovalReconciliationLease {
        let normalizedSession = normalizeSessionId(sessionId)
        guard !normalizedSession.isEmpty else {
            throw CLIError(message: "Cursor approval reconciliation requires a session")
        }
        let lockIdentity = normalizeOptional(surfaceId) ?? normalizedSession
        let digest = Array(SHA256.hash(data: Data(lockIdentity.utf8)))
        var rawOffset: UInt64 = 0
        for byte in digest.prefix(MemoryLayout<UInt64>.size) {
            rawOffset = (rawOffset << 8) | UInt64(byte)
        }
        let lockStart = off_t(rawOffset & 0x3FFF_FFFF_FFFF_FFFF) + 1
        let lockLength: off_t = 1
        let lockPath = statePath + ".cursor-approval-reconcile.lock"
        let lockDirectory = URL(fileURLWithPath: lockPath).deletingLastPathComponent()
        try fileManager.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw CLIError(message: "Failed to open Cursor approval reconciliation lock: \(lockPath)")
        }
        var lock = flock(
            l_start: lockStart,
            l_len: lockLength,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        let lockDeadline = deadline ?? Date.now.addingTimeInterval(3.0)
        while Darwin.fcntl(fd, F_SETLK, &lock) != 0 {
            guard errno == EACCES || errno == EAGAIN, Date.now < lockDeadline else {
                Darwin.close(fd)
                throw CLIError(message: "Failed to lock Cursor approval reconciliation: \(lockPath)")
            }
            usleep(5_000)
        }
        return CursorShellApprovalReconciliationLease(
            fileDescriptor: fd,
            lockStart: lockStart,
            lockLength: lockLength
        )
    }

    private func loadUnlocked(deadline: Date? = nil) throws -> ClaudeHookSessionStoreFile {
        guard fileManager.fileExists(atPath: statePath) else {
            return ClaudeHookSessionStoreFile()
        }
        let stateURL = URL(fileURLWithPath: statePath)
        guard let values = try? stateURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize else {
            throw CLIError(message: "Claude hook state file is unavailable or too large: \(statePath)")
        }
        if deadline != nil, fileSize > Self.maxHookStateFileBytes {
            throw CLIError(message: "Claude hook state file is too large for the hook deadline: \(statePath)")
        }
        if fileSize > Self.maxRecoverableHookStateFileBytes {
            return try quarantineOversizedState(at: stateURL)
        }
        let data = try Data(contentsOf: stateURL)
        guard var decoded = try? decoder.decode(ClaudeHookSessionStoreFile.self, from: data) else {
            return try quarantineOversizedState(at: stateURL)
        }
        if fileSize > Self.maxHookStateFileBytes {
            compactRecoveredState(&decoded)
        }
        backfillSurfaceActiveSlots(&decoded)
        return decoded
    }

    /// Moves an unreadable/oversized state file aside before rebuilding a
    /// bounded store, so hook routing can recover without silently destroying
    /// the user's previous session mappings.
    private func quarantineOversizedState(at url: URL) throws -> ClaudeHookSessionStoreFile {
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).quarantined.json", isDirectory: false)
        try? fileManager.removeItem(at: backupURL)
        try fileManager.moveItem(at: url, to: backupURL)
        return ClaudeHookSessionStoreFile()
    }

    private func reconcileCursorPendingIndex(_ state: inout ClaudeHookSessionStoreFile) {
        let now = Date().timeIntervalSince1970
        var index: [String: [String]] = [:]
        var counts: [String: Int] = [:]
        for (sessionId, record) in state.sessions {
            guard hasUnexpiredCursorShellApproval(record, now: now) else { continue }
            let key = cursorPendingSurfaceKey(surfaceId: record.surfaceId)
            counts[key, default: 0] += 1
            var sessions = index[key] ?? []
            sessions.append(sessionId)
            if sessions.count > Self.maxPendingCursorApprovalIndexEntriesPerSurface {
                sessions.removeFirst(sessions.count - Self.maxPendingCursorApprovalIndexEntriesPerSurface)
            }
            index[key] = sessions
        }
        state.pendingCursorApprovalSessionsBySurface = index
        state.pendingCursorApprovalSessionCountsBySurface = counts
        state.pendingCursorApprovalSurfaceOverflow = counts.reduce(into: [:]) { result, entry in
            if entry.value > Self.maxPendingCursorApprovalIndexEntriesPerSurface {
                result[entry.key] = true
            }
        }
    }

    private func pruneCursorPendingIndex(_ state: inout ClaudeHookSessionStoreFile) {
        let now = Date().timeIntervalSince1970
        var next: [String: [String]] = [:]
        var nextCounts = state.pendingCursorApprovalSessionCountsBySurface
        for (key, sessions) in state.pendingCursorApprovalSessionsBySurface {
            let valid = sessions.filter { sessionId in
                guard let record = state.sessions[sessionId],
                      hasUnexpiredCursorShellApproval(record, now: now) else {
                    return false
                }
                return cursorPendingSurfaceKey(surfaceId: record.surfaceId) == key
            }
            let currentCount = nextCounts[key] ?? sessions.count
            let removedKnownCount = max(0, sessions.count - valid.count)
            let remainingCount = max(0, currentCount - removedKnownCount)
            if remainingCount > 0 {
                nextCounts[key] = remainingCount
            } else {
                nextCounts.removeValue(forKey: key)
            }
            if !valid.isEmpty {
                next[key] = Array(valid.suffix(Self.maxPendingCursorApprovalIndexEntriesPerSurface))
            }
        }
        state.pendingCursorApprovalSessionsBySurface = next
        state.pendingCursorApprovalSessionCountsBySurface = nextCounts.filter { key, count in
            count > 0 && (
                next[key] != nil
                    || count > Self.maxPendingCursorApprovalIndexEntriesPerSurface
                    || state.pendingCursorApprovalSurfaceOverflow[key] == true
            )
        }
        let retainedKeys = Set(state.pendingCursorApprovalSessionCountsBySurface.keys)
        state.pendingCursorApprovalSurfaceOverflow = state.pendingCursorApprovalSurfaceOverflow.filter {
            retainedKeys.contains($0.key)
        }
    }

    private func compactRecoveredState(_ state: inout ClaudeHookSessionStoreFile) {
        guard state.sessions.count > Self.maxRecoveredHookSessions else { return }
        var required = Set(state.activeSessionsByWorkspace.values.map(\.sessionId))
        required.formUnion(state.activeSessionsBySurface.values.map(\.sessionId))
        required.formUnion(state.sessions.compactMap { sessionId, record in
            record.pendingCursorShellApprovals?.isEmpty == false ? sessionId : nil
        })
        let newest = state.sessions
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(Self.maxRecoveredHookSessions)
            .map(\.key)
        let keep = Set(newest).union(required)
        state.sessions = state.sessions.filter { keep.contains($0.key) }
        state.activeSessionsByWorkspace = state.activeSessionsByWorkspace.filter {
            state.sessions[$0.value.sessionId] != nil
        }
        state.activeSessionsBySurface = state.activeSessionsBySurface.filter {
            state.sessions[$0.value.sessionId] != nil
        }
        state.pendingSupersededSessionCleanup = state.pendingSupersededSessionCleanup.filter {
            state.sessions[$0.key] != nil
        }
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

    private func saveUnlocked(_ state: ClaudeHookSessionStoreFile, deadline: Date? = nil) throws {
        if let deadline, Date.now >= deadline {
            throw CLIError(message: "Claude hook state deadline exceeded: \(statePath)")
        }
        let stateURL = URL(fileURLWithPath: statePath)
        let parentURL = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try? fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: parentURL.path)
        let data = try encoder.encode(state)
        if let deadline, Date.now >= deadline {
            throw CLIError(message: "Claude hook state deadline exceeded: \(statePath)")
        }
        let tempURL = parentURL.appendingPathComponent(".\(stateURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: tempURL.path, contents: data, attributes: [
            .posixPermissions: NSNumber(value: Int16(0o600))
        ]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: statePath])
        }
        if let deadline, Date.now >= deadline {
            try? fileManager.removeItem(at: tempURL)
            throw CLIError(message: "Claude hook state deadline exceeded: \(statePath)")
        }
        let renameResult = tempURL.path.withCString { source in
            stateURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        if renameResult != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? fileManager.removeItem(at: tempURL)
            throw POSIXError(code)
        }
        try? fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: stateURL.path)
    }

    private func pruneExpired(_ state: inout ClaudeHookSessionStoreFile) {
        let now = Date().timeIntervalSince1970
        let cutoff = now - Self.maxStateAgeSeconds
        state.sessions = state.sessions.filter { _, record in
            record.updatedAt >= cutoff
        }
        for sessionId in Array(state.sessions.keys) {
            guard var record = state.sessions[sessionId],
                  let pending = record.pendingCursorShellApprovals,
                  pending.count > Self.maxPendingCursorShellApprovals else {
                continue
            }
            // State files are user-writable and may have been produced by an
            // older or interrupted writer. Keep only the newest bounded
            // approvals. Because the dropped prefix may itself be enormous,
            // disable command-only correlation for this session instead of
            // scanning it to build a fence; stable tool ids remain eligible.
            var recentlyCleared = (record.recentlyClearedCursorShellCommandFingerprints ?? [:]).filter {
                now - $0.value <= Self.recentlyClearedCursorShellCommandAgeSeconds
            }
            record.cursorShellCommandOnlyCorrelationDisabled = true
            if recentlyCleared.count > Self.maxRecentlyClearedCursorShellCommandFingerprints {
                record.cursorShellCommandOnlyCorrelationDisabled = true
                recentlyCleared = Dictionary(
                    uniqueKeysWithValues: recentlyCleared.sorted { $0.value > $1.value }
                        .prefix(Self.maxRecentlyClearedCursorShellCommandFingerprints)
                        .map { ($0.key, $0.value) }
                )
            }
            record.recentlyClearedCursorShellCommandFingerprints = recentlyCleared
            record.pendingCursorShellApprovals = Array(pending.suffix(Self.maxPendingCursorShellApprovals))
            state.sessions[sessionId] = record
        }
        state.pendingSupersededSessionCleanup = state.pendingSupersededSessionCleanup.filter { _, record in
            (record.supersededCleanupEnqueuedAt ?? record.updatedAt) >= cutoff
        }
        state.activeSessionsByWorkspace = state.activeSessionsByWorkspace.filter { workspaceId, active in
            guard active.updatedAt >= cutoff, let record = state.sessions[active.sessionId] else { return false }
            // Self-heal cross-workspace/pane pollution: a session may only be active
            // for its own recorded workspace (and surface, below). Stale focused/TTY
            // misroutes from older builds could register a session as active for an
            // unrelated tab or pane, stealing its notifications (isCurrent trusts the
            // surface slot first) and suppressing that pane's own session.
            return normalizeOptional(record.workspaceId) == workspaceId
        }
        state.activeSessionsBySurface = state.activeSessionsBySurface.filter { surfaceId, active in
            active.updatedAt >= cutoff && normalizeOptional(state.sessions[active.sessionId]?.surfaceId) == surfaceId
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
