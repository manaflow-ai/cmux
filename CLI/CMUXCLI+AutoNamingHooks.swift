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
        guard probe["workspace_user_owned"] as? Bool != true else {
            telemetry.breadcrumb("claude-hook.auto-name.user-owned")
            return
        }

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

        guard let transcriptPath = parsedInput.transcriptPath ?? mappedSession?.transcriptPath else { return }
        guard let lines = readRecentTextFileLines(path: transcriptPath, maxBytes: 512 * 1024), !lines.isEmpty else {
            return
        }
        let lineCount = textFileGrowthMetric(path: transcriptPath, fallbackLineCount: lines.count)
        let engine = AutoNamingEngine()
        guard let outcome = try? sessionStore.beginAutoNaming(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            transcriptLineCount: lineCount,
            now: Date(),
            engine: engine
        ) else { return }
        guard case .proceed(let baseline) = outcome.decision else {
            telemetry.breadcrumb("claude-hook.auto-name.throttled")
            return
        }

        var confirmedTitle: String?
        defer {
            try? sessionStore.finishAutoNaming(
                sessionId: sessionId,
                appliedTitle: confirmedTitle,
                baselineLineCount: confirmedTitle != nil ? baseline : nil,
                now: Date()
            )
        }

        let messages = engine.extractMessages(fromTranscriptLines: lines)
        guard let context = engine.buildContext(from: messages) else { return }
        let prompt = engine.buildPrompt(currentTitle: outcome.lastTitle, context: context)

        let resolution = resolvedSummarizerAgent(
            probe: probe, sessionAgent: "claude", env: env, telemetry: telemetry
        )
        guard let rawResponse = summarize(
            summarizerAgent: resolution.agent,
            prompt: prompt,
            env: env,
            timeout: engine.config.llmTimeout,
            telemetry: telemetry
        ) else {
            telemetry.breadcrumb("claude-hook.auto-name.llm-failed")
            reportAutoNamingProblem("failed", agent: resolution.agent, workspaceId: workspaceId, client: client)
            return
        }

        guard let sanitized = engine.sanitizeResponse(rawResponse, currentTitle: nil) else { return }
        confirmedTitle = applyAutoNamingTitle(
            sanitized,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            previousTitle: outcome.lastTitle,
            client: client,
            telemetryKey: "claude-hook.auto-name",
            telemetry: telemetry
        )
        // Re-report a missing override only after the fallback apply, so the
        // app's clear-on-apply doesn't immediately wipe the Settings note.
        if confirmedTitle != nil, let missing = resolution.missingOverride {
            reportAutoNamingProblem("not_installed", agent: missing, workspaceId: workspaceId, client: client)
        }
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
        guard probe["workspace_user_owned"] as? Bool != true else {
            telemetry.breadcrumb("codex-hook.auto-name.user-owned")
            return
        }

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
        let resolution = resolvedSummarizerAgent(
            probe: probe, sessionAgent: "codex", env: env, telemetry: telemetry
        )
        runFileBackedAutoName(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lines: lines,
            lineCount: textFileGrowthMetric(path: transcriptPath, fallbackLineCount: lines.count),
            sessionStore: sessionStore,
            client: client,
            missingOverride: resolution.missingOverride,
            telemetryKey: "codex-hook.auto-name",
            telemetry: telemetry
        ) { engine, outcome in
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
            return raw
        }
    }
}
