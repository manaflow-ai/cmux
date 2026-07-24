import Foundation

extension ClaudeHookSessionStore {
    /// Advances the shared Codex runtime ordering for a causal prompt or Stop boundary.
    func advanceCodexRuntimeStatusOrdering(
        sessionId: String,
        pid: Int?
    ) throws -> (runtime: CodexPermissionRuntimeGeneration, revision: UInt64)? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState { state in
            guard var record = state.sessions[normalized],
                  let runtime = codexPermissionRuntimeGeneration(record: record, incomingPID: pid),
                  codexPermissionRuntimeIsCurrent(record: record, incoming: runtime) else {
                return nil
            }
            let watermark = max(
                record.codexPermissionRevision ?? 0,
                record.codexPermissionState?.revision ?? 0
            )
            guard watermark < UInt64.max else { return nil }
            let revision = watermark + 1
            record.codexPermissionRevision = revision
            record.codexPermissionState = nil
            record.updatedAt = Date.now.timeIntervalSince1970
            state.sessions[normalized] = record
            return (runtime, revision)
        }
    }
}
