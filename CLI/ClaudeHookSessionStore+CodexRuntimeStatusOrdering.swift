import Foundation

extension ClaudeHookSessionStore {
    /// Advances the shared Codex runtime ordering for a causal prompt or Stop boundary.
    func advanceCodexRuntimeStatusOrdering(
        sessionId: String,
        pid: Int?
    ) throws -> (
        runtime: CodexPermissionRuntimeGeneration,
        revision: UInt64,
        notificationIDs: [UUID]
    )? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState { state in
            guard var record = state.sessions[normalized],
                  let runtime = codexPermissionRuntimeGeneration(record: record, incomingPID: pid),
                  codexPermissionRuntimeIsCurrent(record: record, incoming: runtime) else {
                return nil
            }
            let startsNewRuntime = record.codexPermissionState.map {
                !$0.runtime.matches(runtime)
            } ?? false
            let watermark = startsNewRuntime ? 0 : max(
                record.codexPermissionRevision ?? 0,
                record.codexPermissionState?.revision ?? 0
            )
            guard watermark < UInt64.max else { return nil }
            let revision = watermark + 1
            let notificationIDs = record.codexPermissionState?
                .normalizedTrackedRequests
                .filter(\.blocksInput)
                .compactMap(\.notificationID) ?? []
            record.codexPermissionRevision = revision
            record.codexPermissionState = startsNewRuntime ? nil :
                CodexPermissionTransitionMachine().crossOrderingBoundary(
                    current: record.codexPermissionState,
                    runtime: runtime,
                    revision: revision
                )
            record.updatedAt = Date.now.timeIntervalSince1970
            state.sessions[normalized] = record
            return (runtime, revision, notificationIDs)
        }
    }
}
