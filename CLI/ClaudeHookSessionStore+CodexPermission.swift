import Foundation

extension ClaudeHookSessionStore {
    @discardableResult
    func recordCodexPermissionNeedsInput(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        turnId: String? = nil,
        requestId: String? = nil,
        pid: Int?,
        launchCommand: AgentHookLaunchCommandRecord? = nil,
        lastSubtitle: String? = nil,
        lastBody: String? = nil,
        updateNotification: Bool = false
    ) throws -> CodexPermissionTransition? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(
                state: state,
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            )
            guard let runtime = codexPermissionRuntimeGeneration(record: record, incomingPID: pid),
                  codexPermissionRuntimeIsCurrent(record: record, incoming: runtime) else {
                return nil
            }
            let identity = codexPermissionIdentity(turnId: turnId, requestId: requestId)
            if let incomingTurnID = identity.turnID {
                guard !terminalPromptTurnSet(from: record).contains(incomingTurnID) else { return nil }
                if let activeTurnID = activePromptTurnStack(from: record).last,
                   activeTurnID != incomingTurnID {
                    return nil
                }
            }
            let transition = CodexPermissionTransitionMachine.reduce(
                current: record.codexPermissionState,
                event: .permissionRequested,
                identity: identity,
                runtime: runtime,
                notificationID: UUID()
            )
            guard transition.accepted else { return transition }
            update(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                pid: runtime.pid,
                launchCommand: launchCommand,
                isRestorable: nil,
                agentLifecycle: .needsInput,
                lastSubtitle: lastSubtitle,
                lastBody: lastBody,
                lastNotificationStatus: updateNotification ? .needsInput : nil,
                updateLastNotificationStatus: updateNotification,
                runtimeStatus: .needsInput,
                updateRuntimeStatus: true,
                now: now
            )
            record.codexPermissionState = transition.state
            state.sessions[normalized] = record
            return transition
        }
    }

    @discardableResult
    func recordCodexToolStarted(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        turnId: String? = nil,
        requestId: String? = nil,
        pid: Int?,
        launchCommand: AgentHookLaunchCommandRecord? = nil
    ) throws -> CodexPermissionTransition? {
        try recordCodexToolEvent(
            .toolStarted,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: cwd,
            transcriptPath: transcriptPath,
            turnId: turnId,
            requestId: requestId,
            pid: pid,
            launchCommand: launchCommand
        )
    }

    @discardableResult
    func recordCodexToolCompleted(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        turnId: String? = nil,
        requestId: String? = nil,
        pid: Int?,
        launchCommand: AgentHookLaunchCommandRecord? = nil
    ) throws -> CodexPermissionTransition? {
        try recordCodexToolEvent(
            .toolCompleted,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: cwd,
            transcriptPath: transcriptPath,
            turnId: turnId,
            requestId: requestId,
            pid: pid,
            launchCommand: launchCommand
        )
    }

    private func recordCodexToolEvent(
        _ event: CodexPermissionEvent,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        turnId: String?,
        requestId: String?,
        pid: Int?,
        launchCommand: AgentHookLaunchCommandRecord?
    ) throws -> CodexPermissionTransition? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(
                state: state,
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                now: now
            )
            guard let runtime = codexPermissionRuntimeGeneration(record: record, incomingPID: pid),
                  codexPermissionRuntimeIsCurrent(record: record, incoming: runtime) else {
                return nil
            }
            let transition = CodexPermissionTransitionMachine.reduce(
                current: record.codexPermissionState,
                event: event,
                identity: codexPermissionIdentity(turnId: turnId, requestId: requestId),
                runtime: runtime
            )
            guard transition.accepted else { return transition }
            if transition.effect == .resolveNeedsInput {
                update(
                    &record,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: cwd,
                    transcriptPath: transcriptPath,
                    pid: runtime.pid,
                    launchCommand: launchCommand,
                    isRestorable: nil,
                    agentLifecycle: .running,
                    lastSubtitle: nil,
                    lastBody: nil,
                    lastNotificationStatus: nil,
                    updateLastNotificationStatus: true,
                    runtimeStatus: .running,
                    updateRuntimeStatus: true,
                    now: now
                )
                record.lastSubtitle = nil
                record.lastBody = nil
                record.lastEmittedNotificationFingerprint = nil
                record.lastEmittedNotificationAt = nil
                record.recentEmittedNotificationFingerprints = nil
            }
            record.codexPermissionState = transition.state
            record.updatedAt = now
            state.sessions[normalized] = record
            return transition
        }
    }

    func codexPermissionNeedsInputIsCurrent(
        sessionId: String,
        turnId: String?,
        requestId: String?,
        pid: Int?
    ) throws -> Bool {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return false }
        return try withLockedState { state in
            guard let record = state.sessions[normalized],
                  let current = record.codexPermissionState,
                  current.phase == .needsInput,
                  let runtime = codexPermissionRuntimeGeneration(record: record, incomingPID: pid),
                  current.runtime.matches(runtime) else {
                return false
            }
            let reportedIdentity = codexPermissionIdentity(turnId: turnId, requestId: requestId)
            if current.identity.exactlyMatches(reportedIdentity)
                || (!current.identity.isScoped && !reportedIdentity.isScoped) {
                return true
            }
            let identity = reportedIdentity
                .correlatedToUniqueActiveToolStart(
                    in: current.startedIdentities ?? [],
                    excluding: current.resolvedIdentities
                )
            return current.identity.exactlyMatches(identity)
        }
    }

    private func codexPermissionIdentity(
        turnId: String?,
        requestId: String?
    ) -> CodexPermissionSignalIdentity {
        CodexPermissionSignalIdentity(
            turnID: normalizeOptional(turnId),
            requestID: normalizeOptional(requestId)
        )
    }

    private func codexPermissionRuntimeGeneration(
        record: ClaudeHookSessionRecord,
        incomingPID: Int?
    ) -> CodexPermissionRuntimeGeneration? {
        guard let pid = incomingPID ?? record.pid, pid > 0 else { return nil }
        let currentIdentity = processStartIdentity(pid: pid)
        let mayUseStoredIdentity = record.pid == pid && currentIdentity == nil
        return CodexPermissionRuntimeGeneration(
            pid: pid,
            pidStartSeconds: currentIdentity?.seconds ?? (mayUseStoredIdentity ? record.pidStartSeconds : nil),
            pidStartMicroseconds: currentIdentity?.microseconds ?? (mayUseStoredIdentity ? record.pidStartMicroseconds : nil)
        )
    }

    private func codexPermissionRuntimeIsCurrent(
        record: ClaudeHookSessionRecord,
        incoming: CodexPermissionRuntimeGeneration
    ) -> Bool {
        guard let recordedPID = record.pid else { return true }
        guard recordedPID == incoming.pid else { return false }
        let recorded = CodexPermissionRuntimeGeneration(
            pid: recordedPID,
            pidStartSeconds: record.pidStartSeconds,
            pidStartMicroseconds: record.pidStartMicroseconds
        )
        return recorded.matches(incoming)
    }
}
