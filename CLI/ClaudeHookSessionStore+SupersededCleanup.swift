import Foundation

extension ClaudeHookSessionStore {
    private static let maxSupersededCleanupBatchSize = 4

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
        for record in superseded {
            state.sessions.removeValue(forKey: record.sessionId)
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
        return pendingSupersededSessionCleanupCandidates(in: state, owner: owner)
    }

    func pendingSupersededSessionCleanupCandidates(
        for owner: ClaudeHookSessionRecord,
        excludingSessionIds: Set<String> = []
    ) throws -> [ClaudeHookSessionRecord] {
        try withLockedState { state in
            pendingSupersededSessionCleanupCandidates(
                in: state,
                owner: owner,
                excludingSessionIds: excludingSessionIds
            )
        }
    }

    private func pendingSupersededSessionCleanupCandidates(
        in state: ClaudeHookSessionStoreFile,
        owner: ClaudeHookSessionRecord,
        excludingSessionIds: Set<String> = []
    ) -> [ClaudeHookSessionRecord] {
        guard let pid = owner.pid,
              let startSeconds = owner.pidStartSeconds,
              let startMicroseconds = owner.pidStartMicroseconds else {
            return []
        }
        return Array(
            state.pendingSupersededSessionCleanup.values
                .filter {
                    !excludingSessionIds.contains($0.sessionId)
                        && $0.pid == pid
                        && $0.pidStartSeconds == startSeconds
                        && $0.pidStartMicroseconds == startMicroseconds
                }
                .sorted {
                    if $0.startedAt != $1.startedAt {
                        return $0.startedAt < $1.startedAt
                    }
                    if $0.updatedAt != $1.updatedAt {
                        return $0.updatedAt < $1.updatedAt
                    }
                    return $0.sessionId < $1.sessionId
                }
                .prefix(Self.maxSupersededCleanupBatchSize)
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
                      current.updatedAt == candidate.updatedAt else {
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
