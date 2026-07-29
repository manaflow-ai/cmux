import Foundation

extension ClaudeHookSessionStore {
    private static let maxSupersededCleanupBatchSize = 4

    func supersededSessionCleanupCandidates(
        in state: ClaudeHookSessionStoreFile,
        keepingSessionId: String,
        owner: ClaudeHookSessionRecord
    ) -> [ClaudeHookSessionRecord] {
        guard let pid = owner.pid,
              let startSeconds = owner.pidStartSeconds,
              let startMicroseconds = owner.pidStartMicroseconds else {
            return []
        }
        return Array(
            state.sessions.values
                .filter {
                    $0.sessionId != keepingSessionId
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
                guard let current = state.sessions[sessionId],
                      current.pid == candidate.pid,
                      current.pidStartSeconds == candidate.pidStartSeconds,
                      current.pidStartMicroseconds == candidate.pidStartMicroseconds,
                      current.workspaceId == candidate.workspaceId,
                      current.surfaceId == candidate.surfaceId,
                      current.updatedAt == candidate.updatedAt else {
                    continue
                }
                state.sessions.removeValue(forKey: sessionId)
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
