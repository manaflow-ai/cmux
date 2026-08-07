import Foundation

extension ClaudeHookSessionStore {
    enum BlockingToolResolution {
        case restoreRunning
        case keepNeedsInput
        case ignoreUnmatched
    }

    /// Atomically records a blocking Claude tool and its Needs input lifecycle.
    /// A payload without an ID deliberately selects legacy session-wide
    /// completion semantics so older Claude versions cannot become stuck.
    func recordBlockingToolNeedsInput(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        toolUseId: String?,
        lastSubtitle: String,
        lastBody: String
    ) throws {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId) else { return }
        try withLockedState { state in
            let now = Date.now.timeIntervalSince1970
            var record = state.sessions[sessionId] ?? ClaudeHookSessionRecord(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                startedAt: now,
                updatedAt: now
            )
            updateBlockingToolRecord(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                lifecycle: .needsInput,
                lastSubtitle: lastSubtitle,
                lastBody: lastBody,
                now: now
            )
            if let toolUseId = normalizedBlockingToolIdentifier(toolUseId) {
                let pending = (record.pendingBlockingToolUseIds ?? []) + [toolUseId]
                record.pendingBlockingToolUseIds = normalizedBlockingToolUseIds(pending)
            } else {
                record.pendingBlockingToolUseIds = nil
            }
            state.sessions[sessionId] = record
        }
    }

    /// Atomically resolves only the matching blocking tool. A nonempty pending
    /// array enables correlated completion; no tracked IDs retain the legacy
    /// session-wide completion path.
    func resolveBlockingToolInput(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        toolUseId: String?
    ) throws -> BlockingToolResolution {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId) else {
            return .restoreRunning
        }
        return try withLockedState { state in
            let now = Date.now.timeIntervalSince1970
            var record = state.sessions[sessionId] ?? ClaudeHookSessionRecord(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                startedAt: now,
                updatedAt: now
            )

            if let storedPending = record.pendingBlockingToolUseIds {
                let pending = normalizedBlockingToolUseIds(storedPending)
                if !pending.isEmpty {
                    guard let toolUseId = normalizedBlockingToolIdentifier(toolUseId),
                          pending.contains(toolUseId) else {
                        return .ignoreUnmatched
                    }
                    let remaining = pending.filter { $0 != toolUseId }
                    record.pendingBlockingToolUseIds = remaining.isEmpty ? nil : remaining
                    updateBlockingToolRecord(
                        &record,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        cwd: cwd,
                        transcriptPath: transcriptPath,
                        lifecycle: remaining.isEmpty ? .running : .needsInput,
                        lastSubtitle: nil,
                        lastBody: nil,
                        now: now
                    )
                    state.sessions[sessionId] = record
                    return remaining.isEmpty ? .restoreRunning : .keepNeedsInput
                }
            }

            updateBlockingToolRecord(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                lifecycle: .running,
                lastSubtitle: nil,
                lastBody: nil,
                now: now
            )
            state.sessions[sessionId] = record
            return .restoreRunning
        }
    }

    private func updateBlockingToolRecord(
        _ record: inout ClaudeHookSessionRecord,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        lifecycle: AgentHibernationLifecycleState,
        lastSubtitle: String?,
        lastBody: String?,
        now: TimeInterval
    ) {
        record.workspaceId = workspaceId
        if let surfaceId = normalizedBlockingToolIdentifier(surfaceId) {
            record.surfaceId = surfaceId
        }
        if let cwd = normalizedBlockingToolIdentifier(cwd) {
            record.cwd = cwd
        }
        if let transcriptPath = normalizedBlockingToolIdentifier(transcriptPath) {
            record.transcriptPath = transcriptPath
        }
        record.agentLifecycle = lifecycle
        if let lastSubtitle = normalizedBlockingToolIdentifier(lastSubtitle) {
            record.lastSubtitle = lastSubtitle
        }
        if let lastBody = normalizedBlockingToolIdentifier(lastBody) {
            record.lastBody = lastBody
        }
        record.updatedAt = now
    }

    private func normalizedBlockingToolUseIds(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { normalizedBlockingToolIdentifier($0) })).sorted()
    }

    private func normalizedBlockingToolIdentifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
