import Foundation

extension CMUXCLI {
    /// Handles the targeted PostToolUse companion for AskUserQuestion and
    /// ExitPlanMode. Those tools can publish Needs input without a
    /// PermissionRequest in bypass mode; clear that state when the blocking
    /// tool itself finishes, without observing every ordinary tool call. The
    /// wrapper runs each targeted hook synchronously with its tool, while the
    /// session store correlates parallel callbacks by Claude's `tool_use_id`.
    func runClaudeInputResolvedHook(
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        parsedInput: ClaudeHookParsedInput,
        sessionStore: ClaudeHookSessionStore,
        routing: ClaudeHookRoutingContext,
        markFeedTelemetryHandled: () -> Void
    ) throws {
        telemetry.breadcrumb("claude-hook.input-resolved")
        markFeedTelemetryHandled()

        // Each hook is a short-lived CLI process with no app/UI main thread.
        // Read fresh locked state because a process-local cache cannot observe
        // parallel hook processes and would break completion correlation.
        let mappedSession = parsedInput.sessionId.flatMap {
            try? sessionStore.lookup(sessionId: $0)
        }
        var inputResolvedRouting = routing
        inputResolvedRouting.allowsPidProbe = false
        guard let resolvedTarget = try resolveClaudeHookDeliveryTarget(
            mappedSession: mappedSession,
            routing: inputResolvedRouting,
            client: client
        ) else {
            telemetry.breadcrumb("claude-hook.input-resolved.unresolved")
            printClaudeHookAck()
            return
        }

        let workspaceId = resolvedTarget.workspaceId
        let resolvedSurfaceId = resolvedTarget.surfaceId
        let surfaceId = resolvedTarget.isAuthoritative
            ? resolvedSurfaceId
            : (nonEmptyClaudeHookIdentifier(mappedSession?.surfaceId) ?? resolvedSurfaceId)
        let claudePid = mappedSession?.pid
            ?? claudeAgentPID(from: ProcessInfo.processInfo.environment)
        guard shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: resolvedTarget.isAuthoritative ? resolvedSurfaceId : nil,
            telemetry: telemetry
        ) else {
            telemetry.breadcrumb("claude-hook.input-resolved.stale")
            printClaudeHookAck()
            return
        }
        guard !shouldSuppressNestedAgentVisibleMutations(
            currentAgentPID: claudePid,
            env: ProcessInfo.processInfo.environment
        ) else {
            telemetry.breadcrumb("claude-hook.input-resolved.nested-suppressed")
            printClaudeHookAck()
            return
        }

        guard let sessionId = parsedInput.sessionId else {
            telemetry.breadcrumb("claude-hook.input-resolved.missing-session")
            printClaudeHookAck()
            return
        }
        let toolUseId = extractClaudeHookToolUseId(from: parsedInput.rawObject)
        let resolution: ClaudeHookSessionStore.BlockingToolResolution
        do {
            resolution = try sessionStore.resolveBlockingToolInput(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: parsedInput.cwd,
                transcriptPath: parsedInput.transcriptPath,
                toolUseId: toolUseId
            )
        } catch {
            telemetry.breadcrumb(
                "claude-hook.input-resolved.store-error",
                data: ["error": String(describing: error)]
            )
            // Fail open: releasing an absent transient request is a no-op, but
            // withholding release can strand bypass-mode attention forever.
            resolution = .resolved
        }

        switch resolution {
        case .ignoreUnmatched:
            telemetry.breadcrumb("claude-hook.input-resolved.unmatched")
            printClaudeHookAck()
            return
        case .resolved:
            endClaudeBlockingAttention(
                client: client,
                sessionId: sessionId,
                toolUseId: toolUseId
            )
        }
        printClaudeHookAck()
    }
}
