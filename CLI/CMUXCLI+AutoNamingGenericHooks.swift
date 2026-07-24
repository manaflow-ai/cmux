import Foundation

extension CMUXCLI {
    enum AgentAutoNamingSource: Equatable {
        case codexRollout
        case grokHistory
        case hookMessageCache
    }

    func autoNamingSource(for def: AgentHookDef) -> AgentAutoNamingSource? {
        switch def.name {
        case "codex":
            return .codexRollout
        case "grok":
            return .grokHistory
        case "opencode", "pi", "omp":
            return .hookMessageCache
        default:
            return nil
        }
    }

    func usesHookMessageCacheForAutoNaming(_ def: AgentHookDef) -> Bool {
        autoNamingSource(for: def) == .hookMessageCache
    }

    func autoNamingMessages(
        for def: AgentHookDef,
        parsedInput: ClaudeHookParsedInput,
        client: SocketClient,
        workspaceId: String,
        engine: AutoNamingEngine = AutoNamingEngine()
    ) -> [AutoNamingTranscriptMessage] {
        guard usesHookMessageCacheForAutoNaming(def),
              let object = parsedInput.rawObject ?? parsedInput.object else {
            return []
        }
        guard let probe = try? client.sendV2(
            method: "workspace.set_auto_title",
            params: ["probe": true, "workspace_id": workspaceId]
        ), probe["enabled"] as? Bool == true,
           probe["workspace_user_owned"] as? Bool != true else {
            return []
        }
        return engine.extractHookMessages(fromPayloadObjects: [object])
    }

    /// Detached naming pass for non-Codex generic agents.
    func runGenericAgentAutoNameHook(
        def: AgentHookDef,
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        env: [String: String]
    ) {
        guard let source = autoNamingSource(for: def) else { return }
        if case .codexRollout = source { return }
        guard let sessionId = optionValue(commandArgs, name: "--session"),
              let workspaceId = optionValue(commandArgs, name: "--workspace"),
              let surfaceId = optionValue(commandArgs, name: "--surface") else {
            return
        }
        guard let probe = try? client.sendV2(
            method: "workspace.set_auto_title",
            params: ["probe": true, "workspace_id": workspaceId]
        ), probe["enabled"] as? Bool == true else {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.disabled")
            return
        }
        guard probe["workspace_user_owned"] as? Bool != true else {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.user-owned")
            return
        }

        let sessionStore = ClaudeHookSessionStore(processEnv: env)
        let mapped = try? sessionStore.lookup(sessionId: sessionId)
        guard (try? sessionStore.isCurrent(sessionId: sessionId, workspaceId: workspaceId, surfaceId: surfaceId)) ?? false else {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.stale")
            return
        }

        let engine = AutoNamingEngine()
        let sourceResult: (messages: [AutoNamingTranscriptMessage], lineCount: Int)? = {
            switch source {
            case .codexRollout:
                return nil
            case .grokHistory:
                let cwd = normalizedHookValue(optionValue(commandArgs, name: "--cwd")) ?? mapped?.cwd
                guard let sessionURL = grokSessionDirectory(cwd: cwd, sessionId: sessionId, env: env) else {
                    return nil
                }
                let historyURL = sessionURL.appendingPathComponent("chat_history.jsonl", isDirectory: false)
                guard let lines = readRecentTextFileLines(path: historyURL.path, maxBytes: 512 * 1024),
                      !lines.isEmpty else {
                    return nil
                }
                let lineCount = textFileGrowthMetric(path: historyURL.path, fallbackLineCount: lines.count)
                return (engine.extractGrokMessages(fromChatHistoryLines: lines), lineCount)
            case .hookMessageCache:
                guard let snapshot = try? sessionStore.autoNamingRecentMessagesSnapshot(sessionId: sessionId),
                      !snapshot.messages.isEmpty else {
                    return nil
                }
                return (
                    snapshot.messages,
                    engine.hookMessageLineEquivalentCount(
                        snapshot.messages,
                        totalMessageCount: snapshot.totalMessageCount
                    )
                )
            }
        }()
        guard let sourceResult, !sourceResult.messages.isEmpty else { return }

        let resolution = resolvedSummarizerAgent(
            probe: probe, sessionAgent: def.name, env: env, telemetry: telemetry
        )
        runMessageBackedAutoName(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            messages: sourceResult.messages,
            lineCount: sourceResult.lineCount,
            sessionStore: sessionStore,
            client: client,
            missingOverride: resolution.missingOverride,
            telemetryKey: "\(def.name)-hook.auto-name",
            telemetry: telemetry
        ) { engine, outcome in
            guard let context = engine.buildContext(from: sourceResult.messages) else { return nil }
            let prompt = engine.buildPrompt(currentTitle: outcome.lastTitle, context: context)
            guard let raw = summarize(
                summarizerAgent: resolution.agent,
                prompt: prompt,
                env: env,
                timeout: engine.config.llmTimeout,
                telemetry: telemetry
            ) else {
                reportAutoNamingProblem("failed", agent: resolution.agent, workspaceId: workspaceId, client: client)
                return nil
            }
            return raw
        }
    }

    func runFileBackedAutoName(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        lines: [String],
        lineCount: Int,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        missingOverride: String?,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry,
        rawResponse: (AutoNamingEngine, ClaudeHookSessionStore.AutoNamingBeginOutcome) -> String?
    ) {
        guard !lines.isEmpty else { return }
        runAutoNamingPass(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lineCount: lineCount,
            sessionStore: sessionStore,
            client: client,
            missingOverride: missingOverride,
            telemetryKey: telemetryKey,
            telemetry: telemetry,
            rawResponse: rawResponse
        )
    }

    func runMessageBackedAutoName(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        messages: [AutoNamingTranscriptMessage],
        lineCount: Int,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        missingOverride: String?,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry,
        rawResponse: (AutoNamingEngine, ClaudeHookSessionStore.AutoNamingBeginOutcome) -> String?
    ) {
        guard !messages.isEmpty else { return }
        runAutoNamingPass(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lineCount: lineCount,
            sessionStore: sessionStore,
            client: client,
            missingOverride: missingOverride,
            telemetryKey: telemetryKey,
            telemetry: telemetry,
            rawResponse: rawResponse
        )
    }

    private func runAutoNamingPass(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        lineCount: Int,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        missingOverride: String?,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry,
        rawResponse: (AutoNamingEngine, ClaudeHookSessionStore.AutoNamingBeginOutcome) -> String?
    ) {
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
        defer {
            try? sessionStore.finishAutoNaming(
                sessionId: sessionId,
                appliedTitle: confirmedTitle,
                baselineLineCount: confirmedTitle != nil ? baseline : nil,
                now: Date()
            )
        }
        guard let rawResponse = rawResponse(engine, outcome) else {
            telemetry.breadcrumb("\(telemetryKey).llm-failed")
            return
        }
        guard let sanitized = engine.sanitizeResponse(rawResponse, currentTitle: nil) else { return }
        confirmedTitle = applyAutoNamingTitle(
            sanitized,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            previousTitle: outcome.lastTitle,
            client: client,
            telemetryKey: telemetryKey,
            telemetry: telemetry
        )
        // Re-report a missing override only after the apply, so the app's
        // clear-on-apply doesn't immediately wipe the Settings note.
        if confirmedTitle != nil, let missing = missingOverride {
            reportAutoNamingProblem("not_installed", agent: missing, workspaceId: workspaceId, client: client)
        }
    }

    func applyAutoNamingTitle(
        _ title: String,
        workspaceId: String,
        surfaceId: String,
        previousTitle: String?,
        client: SocketClient,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry
    ) -> String? {
        guard let payload = try? client.sendV2(method: "workspace.set_auto_title", params: [
            "workspace_id": workspaceId,
            "panel_id": surfaceId,
            "panel_only_if_multiple": true,
            "title": title
        ]) else {
            telemetry.breadcrumb("\(telemetryKey).socket-failed")
            return nil
        }
        if payload["workspace_applied"] as? Bool == true {
            telemetry.breadcrumb("\(telemetryKey).applied")
            return title
        }
        telemetry.breadcrumb("\(telemetryKey).rejected")
        return previousTitle
    }
}
