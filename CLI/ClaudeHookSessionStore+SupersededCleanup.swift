import Darwin
import Foundation

extension ClaudeHookSessionStore {
    private static let maxSupersededCleanupBatchSize = 4
    private static let maxPendingSupersededCleanupRecords = 128
    private static let maxSupersededCleanupAttempts = 8

    func supersededSessionCleanupCandidates(
        in state: inout ClaudeHookSessionStoreFile,
        keepingSessionId: String,
        owner: ClaudeHookSessionRecord
    ) -> [ClaudeHookSessionRecord] {
        state.pendingSupersededSessionCleanup.removeValue(forKey: keepingSessionId)
        guard let pid = owner.pid,
              let startSeconds = owner.pidStartSeconds,
              let startMicroseconds = owner.pidStartMicroseconds else {
            return []
        }
        // Demote every superseded claimant in the locked store transaction;
        // only the external socket cleanup is deliberately batch-limited.
        let superseded = state.sessions.values.filter {
            $0.sessionId != keepingSessionId
                && $0.pid == pid
                && $0.pidStartSeconds == startSeconds
                && $0.pidStartMicroseconds == startMicroseconds
        }
        let supersededIDs = Set(superseded.map(\.sessionId))
        let enqueuedAt = Date().timeIntervalSince1970
        for var record in superseded {
            state.sessions.removeValue(forKey: record.sessionId)
            record.supersededCleanupEnqueuedAt = enqueuedAt
            record.supersededCleanupLastAttemptAt = nil
            record.supersededCleanupAttemptCount = 0
            state.pendingSupersededSessionCleanup[record.sessionId] = record
        }
        if !supersededIDs.isEmpty {
            state.activeSessionsByWorkspace = state.activeSessionsByWorkspace.filter {
                !supersededIDs.contains($0.value.sessionId)
            }
            state.activeSessionsBySurface = state.activeSessionsBySurface.filter {
                !supersededIDs.contains($0.value.sessionId)
            }
        }
        trimPendingSupersededSessionCleanup(in: &state)
        return claimPendingSupersededSessionCleanupCandidates(in: &state, owner: owner)
    }

    func pendingSupersededSessionCleanupCandidates(
        for owner: ClaudeHookSessionRecord
    ) throws -> [ClaudeHookSessionRecord] {
        try withLockedState(persistTaskSyncSidecar: true) { state in
            claimPendingSupersededSessionCleanupCandidates(in: &state, owner: owner)
        }
    }

    private func claimPendingSupersededSessionCleanupCandidates(
        in state: inout ClaudeHookSessionStoreFile,
        owner: ClaudeHookSessionRecord
    ) -> [ClaudeHookSessionRecord] {
        normalizePendingSupersededSessionCleanupMetadata(in: &state)
        trimPendingSupersededSessionCleanup(in: &state)
        let orderedRecords = state.pendingSupersededSessionCleanup.values.sorted {
            switch ($0.supersededCleanupLastAttemptAt, $1.supersededCleanupLastAttemptAt) {
            case (nil, .some):
                return true
            case (.some, nil):
                return false
            case let (.some(lhs), .some(rhs)) where lhs != rhs:
                return lhs < rhs
            default:
                break
            }
            let lhsEnqueuedAt = $0.supersededCleanupEnqueuedAt ?? $0.updatedAt
            let rhsEnqueuedAt = $1.supersededCleanupEnqueuedAt ?? $1.updatedAt
            if lhsEnqueuedAt != rhsEnqueuedAt {
                return lhsEnqueuedAt < rhsEnqueuedAt
            }
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return $0.sessionId < $1.sessionId
        }
        var candidates: [ClaudeHookSessionRecord] = []
        for record in orderedRecords {
            guard Self.sameProcessGeneration(record, owner)
                    || Self.processGenerationIsConfirmedDead(record) else {
                continue
            }
            candidates.append(record)
            if candidates.count == Self.maxSupersededCleanupBatchSize {
                break
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Claiming a batch advances its durable retry order before external
        // socket work begins. Failed records therefore rotate behind records
        // that have not been tried yet, and concurrent hooks do not repeatedly
        // select the same oldest four.
        var claimed: [ClaudeHookSessionRecord] = []
        var attemptedAt = Date().timeIntervalSince1970
        for candidate in candidates {
            guard var current = state.pendingSupersededSessionCleanup[candidate.sessionId],
                  current.pid == candidate.pid,
                  current.pidStartSeconds == candidate.pidStartSeconds,
                  current.pidStartMicroseconds == candidate.pidStartMicroseconds,
                  current.workspaceId == candidate.workspaceId,
                  current.surfaceId == candidate.surfaceId,
                  current.updatedAt == candidate.updatedAt,
                  current.supersededCleanupEnqueuedAt == candidate.supersededCleanupEnqueuedAt,
                  current.supersededCleanupLastAttemptAt == candidate.supersededCleanupLastAttemptAt,
                  current.supersededCleanupAttemptCount == candidate.supersededCleanupAttemptCount else {
                continue
            }
            current.supersededCleanupLastAttemptAt = attemptedAt
            current.supersededCleanupAttemptCount = (current.supersededCleanupAttemptCount ?? 0) + 1
            attemptedAt = attemptedAt.nextUp
            state.pendingSupersededSessionCleanup[candidate.sessionId] = current
            claimed.append(current)
        }
        return claimed
    }

    private func normalizePendingSupersededSessionCleanupMetadata(
        in state: inout ClaudeHookSessionStoreFile
    ) {
        for sessionId in Array(state.pendingSupersededSessionCleanup.keys) {
            guard var record = state.pendingSupersededSessionCleanup[sessionId] else { continue }
            if record.supersededCleanupEnqueuedAt == nil {
                record.supersededCleanupEnqueuedAt = record.updatedAt
            }
            if record.supersededCleanupAttemptCount == nil {
                record.supersededCleanupAttemptCount = 0
            }
            state.pendingSupersededSessionCleanup[sessionId] = record
        }
    }

    private func trimPendingSupersededSessionCleanup(
        in state: inout ClaudeHookSessionStoreFile
    ) {
        state.pendingSupersededSessionCleanup = state.pendingSupersededSessionCleanup.filter { _, record in
            (record.supersededCleanupAttemptCount ?? 0) < Self.maxSupersededCleanupAttempts
        }
        guard state.pendingSupersededSessionCleanup.count > Self.maxPendingSupersededCleanupRecords else {
            return
        }
        let keptSessionIDs = Set(
            state.pendingSupersededSessionCleanup.values
                .sorted {
                    let lhsEnqueuedAt = $0.supersededCleanupEnqueuedAt ?? $0.updatedAt
                    let rhsEnqueuedAt = $1.supersededCleanupEnqueuedAt ?? $1.updatedAt
                    if lhsEnqueuedAt != rhsEnqueuedAt {
                        return lhsEnqueuedAt > rhsEnqueuedAt
                    }
                    return $0.sessionId > $1.sessionId
                }
                .prefix(Self.maxPendingSupersededCleanupRecords)
                .map(\.sessionId)
        )
        state.pendingSupersededSessionCleanup = state.pendingSupersededSessionCleanup.filter {
            keptSessionIDs.contains($0.key)
        }
    }

    private static func sameProcessGeneration(
        _ lhs: ClaudeHookSessionRecord,
        _ rhs: ClaudeHookSessionRecord
    ) -> Bool {
        guard let pid = lhs.pid,
              let startSeconds = lhs.pidStartSeconds,
              let startMicroseconds = lhs.pidStartMicroseconds else {
            return false
        }
        return rhs.pid == pid
            && rhs.pidStartSeconds == startSeconds
            && rhs.pidStartMicroseconds == startMicroseconds
    }

    private static func processGenerationIsConfirmedDead(_ record: ClaudeHookSessionRecord) -> Bool {
        guard let pid = record.pid,
              pid > 0,
              pid <= Int(Int32.max),
              let startSeconds = record.pidStartSeconds,
              let startMicroseconds = record.pidStartMicroseconds else {
            return false
        }

        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        if size == expectedSize {
            return Int64(info.pbi_start_tvsec) != startSeconds
                || Int64(info.pbi_start_tvusec) != startMicroseconds
        }

        if Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM {
            return false
        }
        return errno == ESRCH
    }

    func acknowledgeSupersededSessionCleanup(_ candidates: [ClaudeHookSessionRecord]) throws {
        guard !candidates.isEmpty else { return }
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.sessionId, $0) })
        try withLockedState(persistTaskSyncSidecar: true) { state in
            var acknowledgedIDs: Set<String> = []
            for (sessionId, candidate) in candidatesByID {
                guard let current = state.pendingSupersededSessionCleanup[sessionId],
                      current.pid == candidate.pid,
                      current.pidStartSeconds == candidate.pidStartSeconds,
                      current.pidStartMicroseconds == candidate.pidStartMicroseconds,
                      current.workspaceId == candidate.workspaceId,
                      current.surfaceId == candidate.surfaceId,
                      current.updatedAt == candidate.updatedAt,
                      current.supersededCleanupEnqueuedAt == candidate.supersededCleanupEnqueuedAt,
                      current.supersededCleanupLastAttemptAt == candidate.supersededCleanupLastAttemptAt,
                      current.supersededCleanupAttemptCount == candidate.supersededCleanupAttemptCount else {
                    continue
                }
                state.pendingSupersededSessionCleanup.removeValue(forKey: sessionId)
                acknowledgedIDs.insert(sessionId)
            }
            guard !acknowledgedIDs.isEmpty else { return }
            state.activeSessionsByWorkspace = state.activeSessionsByWorkspace.filter {
                !acknowledgedIDs.contains($0.value.sessionId)
            }
            state.activeSessionsBySurface = state.activeSessionsBySurface.filter {
                !acknowledgedIDs.contains($0.value.sessionId)
            }
        }
    }
}
