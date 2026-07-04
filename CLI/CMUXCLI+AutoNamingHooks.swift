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
        let telemetryKey = "claude-hook.auto-name"
        guard let probe = probeAutoNaming(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            agent: "claude",
            client: client,
            telemetryKey: telemetryKey,
            telemetry: telemetry
        ) else {
            return
        }
        let promptLanguage = autoNamingPromptLanguage(
            probe: probe,
            env: env,
            telemetryKey: telemetryKey,
            telemetry: telemetry
        )
        let currentTitle = autoNamingCurrentTitle(probe: probe)
        let panelTitleTarget = autoNamingTargetsPanel(probe: probe)

        let claudePid = mappedSession?.pid ?? claudeAgentPID(from: env)
        guard !shouldSuppressNestedAgentVisibleMutations(currentAgentPID: claudePid, env: env) else {
            telemetry.breadcrumb("\(telemetryKey).nested-suppressed")
            return
        }
        guard shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            telemetry: telemetry
        ) else {
            telemetry.breadcrumb("\(telemetryKey).stale")
            return
        }

        guard let transcriptPath = parsedInput.transcriptPath ?? mappedSession?.transcriptPath else {
            telemetry.breadcrumb("\(telemetryKey).transcript-missing")
            reportAutoNamingProblem("extraction_failed", agent: "claude", workspaceId: workspaceId, client: client)
            return
        }
        guard let lines = readRecentTextFileLines(path: transcriptPath, maxBytes: 512 * 1024), !lines.isEmpty else {
            telemetry.breadcrumb("\(telemetryKey).transcript-unreadable")
            reportAutoNamingProblem("extraction_failed", agent: "claude", workspaceId: workspaceId, client: client)
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
            telemetry.breadcrumb("\(telemetryKey).throttled")
            return
        }

        var confirmedTitle: String?
        var countFailure = true
        defer {
            _ = try? sessionStore.finishAutoNaming(
                sessionId: sessionId,
                passId: outcome.passId,
                appliedTitle: confirmedTitle,
                baselineLineCount: confirmedTitle != nil ? baseline : nil,
                now: Date(),
                countFailure: countFailure
            )
        }
        let extraction = engine.extractClaudeTranscript(fromTranscriptLines: lines)
        if let diagnostic = extraction.diagnosticSummary {
            telemetry.breadcrumb("\(telemetryKey).extraction.\(diagnostic)")
        }
        guard let context = engine.buildContext(from: extraction.messages) else {
            countFailure = false
            telemetry.breadcrumb("\(telemetryKey).extraction-empty")
            reportAutoNamingProblem("extraction_failed", agent: "claude", workspaceId: workspaceId, client: client)
            return
        }
        let prompt = engine.buildPrompt(
            currentTitle: currentTitle,
            context: context,
            language: promptLanguage
        )

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
            telemetry.breadcrumb("\(telemetryKey).llm-failed")
            reportAutoNamingProblem("failed", agent: resolution.agent, workspaceId: workspaceId, client: client)
            return
        }

        guard let action = autoNamingSanitizedAction(
            engine: engine,
            rawResponse: rawResponse,
            currentTitle: currentTitle,
            telemetryKey: telemetryKey,
            telemetry: telemetry
        ) else { return }
        guard (try? sessionStore.isCurrentAutoNamingPass(sessionId: sessionId, passId: outcome.passId)) == true else {
            telemetry.breadcrumb("\(telemetryKey).stale-pass")
            countFailure = false
            return
        }
        if action.shouldApply {
            let applyResult = applyAutoNamingTitle(
                action.title,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                agent: resolution.agent,
                client: client,
                panelTitleTarget: panelTitleTarget,
                telemetryKey: telemetryKey,
                telemetry: telemetry
            )
            confirmedTitle = applyResult.confirmedTitle
            countFailure = applyResult.countsTowardBackoff
        } else {
            let noOpResult = confirmAutoNamingNoOpTitle(
                action.title,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                agent: resolution.agent,
                client: client,
                telemetryKey: telemetryKey,
                telemetry: telemetry
            )
            confirmedTitle = noOpResult.confirmed ? action.title : nil
            countFailure = noOpResult.countsTowardBackoff
        }
        // Re-report a missing override only after the fallback pass succeeds,
        // so clear-on-apply does not immediately wipe the Settings note.
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
        let telemetryKey = "codex-hook.auto-name"
        guard let probe = probeAutoNaming(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            agent: "codex",
            client: client,
            telemetryKey: telemetryKey,
            telemetry: telemetry
        ) else {
            return
        }
        let promptLanguage = autoNamingPromptLanguage(
            probe: probe,
            env: env,
            telemetryKey: telemetryKey,
            telemetry: telemetry
        )
        let currentTitle = autoNamingCurrentTitle(probe: probe)
        let panelTitleTarget = autoNamingTargetsPanel(probe: probe)

        let sessionStore = ClaudeHookSessionStore(processEnv: env)
        guard (try? sessionStore.isCurrent(sessionId: sessionId, workspaceId: workspaceId, surfaceId: surfaceId)) ?? false else {
            telemetry.breadcrumb("\(telemetryKey).stale")
            return
        }
        let transcriptPath = normalizedHookValue(optionValue(commandArgs, name: "--transcript"))
            ?? findCodexTranscriptPath(sessionId: sessionId, env: env)
        guard let transcriptPath,
              let lines = readRecentTextFileLines(path: transcriptPath, maxBytes: 512 * 1024),
              !lines.isEmpty else {
            telemetry.breadcrumb("\(telemetryKey).transcript-unreadable")
            reportAutoNamingProblem("extraction_failed", agent: "codex", workspaceId: workspaceId, client: client)
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
            summarizerAgent: resolution.agent,
            missingOverride: resolution.missingOverride,
            currentTitle: currentTitle,
            panelTitleTarget: panelTitleTarget,
            telemetryKey: telemetryKey,
            telemetry: telemetry
        ) { engine, _ in
            let extraction = engine.extractCodexRollout(fromRolloutLines: lines)
            if let diagnostic = extraction.diagnosticSummary {
                telemetry.breadcrumb("\(telemetryKey).extraction.\(diagnostic)")
            }
            guard let context = engine.buildContext(from: extraction.messages) else {
                telemetry.breadcrumb("\(telemetryKey).extraction-empty")
                reportAutoNamingProblem("extraction_failed", agent: "codex", workspaceId: workspaceId, client: client)
                return (nil, false)
            }
            let prompt = engine.buildPrompt(
                currentTitle: currentTitle,
                context: context,
                language: promptLanguage
            )
            guard let raw = summarize(
                summarizerAgent: resolution.agent,
                prompt: prompt,
                env: env,
                timeout: engine.config.llmTimeout,
                telemetry: telemetry
            ) else {
                telemetry.breadcrumb("\(telemetryKey).llm-failed")
                reportAutoNamingProblem("failed", agent: resolution.agent, workspaceId: workspaceId, client: client)
                return (nil, true)
            }
            return (raw, true)
        }
    }
}
