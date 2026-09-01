import Foundation

extension ClaudeHookSessionStore {
    private static let maxSupersededCleanupBatchSize = 4
    private static let maxPendingSupersededCleanupRecords = 128
    private static let maxSupersededCleanupAttempts = 8

    /// Demotes same-process session aliases only after the replacement's app
    /// lifecycle claim has committed. Keeping this outside the reversible
    /// session-start write makes rollback local to one durable record.
    func supersedeSameProcessSessions(
        keepingSessionId: String,
        expectedProcessIdentity: AgentHookProcessIdentity
    ) throws -> [ClaudeHookSessionRecord] {
        try withLockedState { state in
            guard let owner = state.sessions[keepingSessionId],
                  AgentHookProcessIdentity(record: owner) == expectedProcessIdentity else {
                return []
            }
            return supersededSessionCleanupCandidates(
                in: &state,
                keepingSessionId: keepingSessionId,
                owner: owner
            )
        }
    }

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
        // only the external socket cleanup is deliberately batch-limited. A
        // pre-generation OMP record has no birth fields, so a same-PID legacy
        // alias is migrated to the already-verified owner's identity before it
        // enters the retry queue. This keeps old aliases from remaining live
        // forever while limiting the fallback to one process-owned OMP store.
        var superseded: [ClaudeHookSessionRecord] = []
        for candidate in state.sessions.values where candidate.sessionId != keepingSessionId {
            let exactGeneration = candidate.pid == pid
                && candidate.pidStartSeconds == startSeconds
                && candidate.pidStartMicroseconds == startMicroseconds
            let legacyGeneration = candidate.pid == pid
                && candidate.pidStartSeconds == nil
                && candidate.pidStartMicroseconds == nil
            guard exactGeneration || legacyGeneration else { continue }
            var migrated = candidate
            if legacyGeneration {
                migrated.pidStartSeconds = startSeconds
                migrated.pidStartMicroseconds = startMicroseconds
            }
            superseded.append(migrated)
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
        try withLockedState { state in
            claimPendingSupersededSessionCleanupCandidates(in: &state, owner: owner)
        }
    }

    private func claimPendingSupersededSessionCleanupCandidates(
        in state: inout ClaudeHookSessionStoreFile,
        owner: ClaudeHookSessionRecord
    ) -> [ClaudeHookSessionRecord] {
        normalizePendingSupersededSessionCleanupMetadata(in: &state)
        if let ownerIdentity = AgentHookProcessIdentity(record: owner) {
            // Older persisted retry entries may predate birth-time capture.
            // Stamp only same-PID entries from this OMP store with the owner
            // generation so they can take the normal guarded cleanup path.
            for sessionId in Array(state.pendingSupersededSessionCleanup.keys) {
                guard var record = state.pendingSupersededSessionCleanup[sessionId],
                      record.pid == ownerIdentity.pid,
                      record.pidStartSeconds == nil,
                      record.pidStartMicroseconds == nil else {
                    continue
                }
                record.pidStartSeconds = ownerIdentity.startSeconds
                record.pidStartMicroseconds = ownerIdentity.startMicroseconds
                state.pendingSupersededSessionCleanup[sessionId] = record
            }
        }
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
        guard let lhsIdentity = AgentHookProcessIdentity(record: lhs),
              let rhsIdentity = AgentHookProcessIdentity(record: rhs) else {
            return false
        }
        return lhsIdentity == rhsIdentity
    }

    private static func processGenerationIsConfirmedDead(_ record: ClaudeHookSessionRecord) -> Bool {
        guard let recordedIdentity = AgentHookProcessIdentity(record: record) else {
            return false
        }

        if let liveIdentity = AgentHookProcessIdentity(livePID: recordedIdentity.pid) {
            return liveIdentity != recordedIdentity
        }

        return AgentHookProcessIdentity.processGenerationIsConfirmedDead(
            pid: recordedIdentity.pid
        )
    }

    func acknowledgeSupersededSessionCleanup(_ candidates: [ClaudeHookSessionRecord]) throws {
        guard !candidates.isEmpty else { return }
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.sessionId, $0) })
        try withLockedState { state in
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
