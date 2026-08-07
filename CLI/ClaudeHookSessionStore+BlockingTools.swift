import Foundation

extension ClaudeHookSessionStore {
    enum BlockingToolResolution: Equatable {
        case resolved
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

    /// Atomically resolves only the matching blocking tool. A non-nil pending
    /// array enables correlated completion, including an empty array retained
    /// as a tombstone so a later duplicate PostToolUse cannot fall back to the
    /// legacy session-wide path. Records predating correlation keep `nil`.
    func resolveBlockingToolInput(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        toolUseId: String?
    ) throws -> BlockingToolResolution {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId) else {
            return .resolved
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

            let resolution = resolveBlockingTool(
                in: &record,
                toolUseId: toolUseId,
                now: now
            )
            guard resolution == .resolved else { return resolution }
            updateBlockingToolRecord(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                lifecycle: record.pendingBlockingToolUseIds?.isEmpty == false
                    ? .needsInput
                    : .running,
                lastSubtitle: nil,
                lastBody: nil,
                now: now
            )
            state.sessions[sessionId] = record
            return .resolved
        }
    }

    /// Retires a PermissionRequest after Feed reaches a terminal response
    /// without rewriting delivery routing. Feed owns visible attention for
    /// this path; the store only prevents a denied or timed-out tool from
    /// poisoning a later blocker.
    func resolveBlockingToolPermissionRequest(
        sessionId: String,
        toolUseId: String?
    ) throws -> BlockingToolResolution {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId) else {
            return .resolved
        }
        return try withLockedState { state in
            guard var record = state.sessions[sessionId] else {
                return .ignoreUnmatched
            }
            let resolution = resolveBlockingTool(
                in: &record,
                toolUseId: toolUseId,
                now: Date.now.timeIntervalSince1970
            )
            guard resolution == .resolved else { return resolution }
            state.sessions[sessionId] = record
            return .resolved
        }
    }

    private func resolveBlockingTool(
        in record: inout ClaudeHookSessionRecord,
        toolUseId: String?,
        now: TimeInterval
    ) -> BlockingToolResolution {
        if let storedPending = record.pendingBlockingToolUseIds {
            let pending = normalizedBlockingToolUseIds(storedPending)
            guard let toolUseId = normalizedBlockingToolIdentifier(toolUseId),
                  pending.contains(toolUseId) else {
                return .ignoreUnmatched
            }
            let remaining = pending.filter { $0 != toolUseId }
            record.pendingBlockingToolUseIds = remaining
            record.agentLifecycle = remaining.isEmpty ? .running : .needsInput
            record.updatedAt = now
            return .resolved
        }

        // Legacy records lack IDs, so the only safe behavior is the historic
        // session-wide resolution. New correlated records never return to nil.
        record.agentLifecycle = .running
        record.updatedAt = now
        return .resolved
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
