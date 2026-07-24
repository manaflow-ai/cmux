import Darwin
import Foundation

extension CMUXCLI {
    /// Drives one auto-naming pass for a Claude session at turn end.
    func runClaudeAutoNameHook(
        parsedInput: ClaudeHookParsedInput,
        mappedSession: ClaudeHookSessionRecord?,
        workspaceId: String,
        surfaceId: String,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry
    ) {
        guard let sessionId = parsedInput.sessionId else { return }
        let env = ProcessInfo.processInfo.environment
        guard let probe = try? client.sendV2(
            method: "workspace.set_auto_title",
            params: ["probe": true, "workspace_id": workspaceId]
        ), probe["enabled"] as? Bool == true else {
            telemetry.breadcrumb("claude-hook.auto-name.disabled")
            return
        }
        let workspaceUserOwned = probe["workspace_user_owned"] as? Bool == true

        let claudePid = mappedSession?.pid ?? claudeAgentPID(from: env)
        guard !shouldSuppressNestedAgentVisibleMutations(currentAgentPID: claudePid, env: env) else {
            telemetry.breadcrumb("claude-hook.auto-name.nested-suppressed")
            return
        }
        guard shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            telemetry: telemetry
        ) else {
            telemetry.breadcrumb("claude-hook.auto-name.stale")
            return
        }

        let transcriptSnapshot: (lines: [String], lineCount: Int)? = {
            guard let transcriptPath = parsedInput.transcriptPath ?? mappedSession?.transcriptPath,
                  let lines = readRecentTextFileLines(path: transcriptPath, maxBytes: 512 * 1024),
                  !lines.isEmpty else { return nil }
            return (
                lines,
                textFileGrowthMetric(path: transcriptPath, fallbackLineCount: lines.count)
            )
        }()
        if reconcilePendingAutoNamingTitleIfNeeded(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            transcriptLineCount: transcriptSnapshot?.lineCount,
            clearPendingOnConfirmation: true,
            sessionStore: sessionStore,
            client: client,
            telemetryKey: "claude-hook.auto-name.pending-reconcile",
            telemetry: telemetry
        ) {
            return
        }
        guard let transcriptSnapshot else { return }
        let lines = transcriptSnapshot.lines
        runFileBackedAutoName(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lines: lines,
            lineCount: transcriptSnapshot.lineCount,
            sessionStore: sessionStore,
            client: client,
            allowSummarization: !workspaceUserOwned,
            telemetryKey: "claude-hook.auto-name",
            telemetry: telemetry
        ) { engine, outcome in
            let resolution = resolvedSummarizerAgent(
                probe: probe, sessionAgent: "claude", env: env, telemetry: telemetry
            )
            let messages = engine.extractMessages(fromTranscriptLines: lines)
            guard let context = engine.buildContext(from: messages) else { return nil }
            let prompt = engine.buildPrompt(currentTitle: outcome.lastTitle, context: context)
            guard let rawResponse = summarize(
                summarizerAgent: resolution.agent,
                prompt: prompt,
                env: env,
                timeout: engine.config.llmTimeout,
                telemetry: telemetry
            ) else {
                reportAutoNamingProblem("failed", agent: resolution.agent, workspaceId: workspaceId, client: client)
                return nil
            }
            return (response: rawResponse, missingOverride: resolution.missingOverride)
        }
    }

    /// Handles Claude's explicit compact lifecycle event. The immediate replay
    /// is best-effort because matching SessionStart hooks have no guaranteed
    /// ordering; the durable obligation remains for the next Stop even after a
    /// successful apply.
    func runClaudeCompactAutoNameHook(
        parsedInput: ClaudeHookParsedInput,
        workspaceId: String,
        surfaceId: String,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry
    ) {
        guard let sessionId = parsedInput.sessionId else { return }
        let env = ProcessInfo.processInfo.environment
        let mappedSession = try? sessionStore.lookup(sessionId: sessionId)
        let claudePid = mappedSession?.pid ?? claudeAgentPID(from: env)
        guard !shouldSuppressNestedAgentVisibleMutations(currentAgentPID: claudePid, env: env) else {
            telemetry.breadcrumb("claude-hook.auto-name.compact.nested-suppressed")
            return
        }
        guard shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            telemetry: telemetry
        ) else {
            telemetry.breadcrumb("claude-hook.auto-name.compact.stale")
            return
        }
        guard (try? sessionStore.markAutoNamingTitleReconciliationPending(sessionId: sessionId)) != nil else {
            telemetry.breadcrumb("claude-hook.auto-name.compact.no-title")
            return
        }
        guard let probe = try? client.sendV2(
            method: "workspace.set_auto_title",
            params: ["probe": true, "workspace_id": workspaceId]
        ), probe["enabled"] as? Bool == true else {
            telemetry.breadcrumb("claude-hook.auto-name.compact.disabled")
            return
        }
        _ = reconcilePendingAutoNamingTitleIfNeeded(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            transcriptLineCount: nil,
            clearPendingOnConfirmation: false,
            sessionStore: sessionStore,
            client: client,
            telemetryKey: "claude-hook.auto-name.compact.reconcile",
            telemetry: telemetry
        )
    }

    /// Spawns a detached generic-agent auto-name pass via a bounded shell wrapper.
    func spawnDetachedAgentAutoName(
        def: AgentHookDef,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        transcriptPath: String?,
        cwd: String?,
        env: [String: String],
        telemetry: CLISocketSentryTelemetry
    ) {
        let selfPath: String = {
            if let first = ProcessInfo.processInfo.arguments.first,
               first.hasPrefix("/"),
               FileManager.default.isExecutableFile(atPath: first) {
                return first
            }
            if let bundled = normalizedHookValue(env["CMUX_BUNDLED_CLI_PATH"]),
               FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
            return "cmux"
        }()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "\"$0\" hooks \"$1\" auto-name --session \"$2\" --workspace \"$3\" --surface \"$4\" --transcript \"$5\" --cwd \"$6\" </dev/null >/dev/null 2>&1 &",
            selfPath,
            def.name,
            sessionId,
            workspaceId,
            surfaceId,
            transcriptPath ?? "",
            cwd ?? ""
        ]
        var spawnEnv = env
        spawnEnv["CMUX_CLAUDE_HOOK_STATE_PATH"] = agentHookStatePath(sessionStoreSuffix: def.sessionStoreSuffix, env: env)
        process.environment = spawnEnv
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.spawn-failed")
            return
        }
        if ((try? waitForProcessExit(process, timeout: 2)) ?? false) == false {
            process.terminate()
            if ((try? waitForProcessExit(process, timeout: 1)) ?? false) == false {
                kill(process.processIdentifier, SIGKILL)
                _ = try? waitForProcessExit(process, timeout: 1)
            }
        }
    }

    /// Detached Codex naming pass.
    func runCodexAutoNameHook(
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        env: [String: String]
    ) {
        guard let sessionId = optionValue(commandArgs, name: "--session"),
              let workspaceId = optionValue(commandArgs, name: "--workspace"),
              let surfaceId = optionValue(commandArgs, name: "--surface") else {
            return
        }
        guard let probe = try? client.sendV2(
            method: "workspace.set_auto_title",
            params: ["probe": true, "workspace_id": workspaceId]
        ), probe["enabled"] as? Bool == true else {
            telemetry.breadcrumb("codex-hook.auto-name.disabled")
            return
        }
        let workspaceUserOwned = probe["workspace_user_owned"] as? Bool == true

        let sessionStore = ClaudeHookSessionStore(processEnv: env)
        guard (try? sessionStore.isCurrent(sessionId: sessionId, workspaceId: workspaceId, surfaceId: surfaceId)) ?? false else {
            telemetry.breadcrumb("codex-hook.auto-name.stale")
            return
        }
        let transcriptPath = normalizedHookValue(optionValue(commandArgs, name: "--transcript"))
            ?? findCodexTranscriptPath(sessionId: sessionId, env: env)
        guard let transcriptPath,
              let lines = readRecentTextFileLines(path: transcriptPath, maxBytes: 512 * 1024),
              !lines.isEmpty else {
            return
        }
        runFileBackedAutoName(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lines: lines,
            lineCount: textFileGrowthMetric(path: transcriptPath, fallbackLineCount: lines.count),
            sessionStore: sessionStore,
            client: client,
            allowSummarization: !workspaceUserOwned,
            telemetryKey: "codex-hook.auto-name",
            telemetry: telemetry
        ) { engine, outcome in
            let resolution = resolvedSummarizerAgent(
                probe: probe, sessionAgent: "codex", env: env, telemetry: telemetry
            )
            let messages = engine.extractCodexMessages(fromRolloutLines: lines)
            guard let context = engine.buildContext(from: messages) else { return nil }
            let prompt = engine.buildPrompt(currentTitle: outcome.lastTitle, context: context)
            guard let raw = summarize(
                summarizerAgent: resolution.agent,
                prompt: prompt,
                env: env,
                timeout: engine.config.llmTimeout,
                telemetry: telemetry
            ) else {
                telemetry.breadcrumb("codex-hook.auto-name.llm-failed")
                reportAutoNamingProblem("failed", agent: resolution.agent, workspaceId: workspaceId, client: client)
                return nil
            }
            return (response: raw, missingOverride: resolution.missingOverride)
        }
    }

    /// Returns the separately confirmed workspace and panel outcomes, or a
    /// failure when the socket request or response fails.
    func applyAutoNamingTitle(
        _ title: String,
        workspaceId: String,
        surfaceId: String,
        expectedWorkspaceTitle: String? = nil,
        clearStatusOnApply: Bool = true,
        client: SocketClient,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry
    ) -> Result<(titleApplied: Bool, targetsResolved: Bool), CLIError> {
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "panel_id": surfaceId,
            "panel_only_if_multiple": true,
            "clear_status_on_apply": clearStatusOnApply,
            "title": title
        ]
        if let expectedWorkspaceTitle {
            params["expected_workspace_title"] = expectedWorkspaceTitle
        }
        let payload: [String: Any]
        do {
            payload = try client.sendV2(method: "workspace.set_auto_title", params: params)
        } catch {
            telemetry.breadcrumb("\(telemetryKey).socket-failed")
            return .failure(CLIError(message: String(describing: error)))
        }
        let workspaceApplied = payload["workspace_applied"] as? Bool == true
        let workspaceApplySkipped = payload["workspace_apply_skipped"] as? Bool == true
        let panelApplied = payload["panel_applied"] as? Bool
        let workspaceResolved = workspaceApplied
            || workspaceApplySkipped
        let panelResolved = panelApplied != nil
            || payload["panel_apply_skipped"] as? Bool == true
        let titleApplied = workspaceApplied || panelApplied == true
        if titleApplied {
            telemetry.breadcrumb("\(telemetryKey).applied")
        } else if workspaceApplySkipped {
            telemetry.breadcrumb("\(telemetryKey).preserved-workspace-title")
        } else {
            telemetry.breadcrumb("\(telemetryKey).rejected")
        }
        return .success((
            titleApplied: titleApplied,
            targetsResolved: workspaceResolved && panelResolved
        ))
    }
}
