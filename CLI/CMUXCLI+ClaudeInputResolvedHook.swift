import Foundation

extension CMUXCLI {
    /// Handles the targeted PostToolUse companion for AskUserQuestion and
    /// ExitPlanMode. Those tools can publish Needs input without a
    /// PermissionRequest in bypass mode; clear that state when the blocking
    /// tool itself finishes, without observing every ordinary tool call. The
    /// wrapper runs the targeted PreToolUse and PostToolUse hooks synchronously
    /// so this completion cannot overtake the next blocking-tool transition.
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

        if let sessionId = parsedInput.sessionId {
            _ = try? sessionStore.upsert(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: parsedInput.cwd,
                transcriptPath: parsedInput.transcriptPath,
                agentLifecycle: .running
            )
        }
        _ = try? sendV1Command(
            "clear_notifications --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
            client: client
        )
        setAgentLifecycle(
            client: client,
            key: "claude_code",
            lifecycle: .running,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        try setClaudeStatus(
            client: client,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            value: String(
                localized: "agent.generic.status.running",
                defaultValue: "Running"
            ),
            icon: "bolt.fill",
            color: "#4C8DFF",
            pid: claudePid
        )
        printClaudeHookAck()
    }
}
