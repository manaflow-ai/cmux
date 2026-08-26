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

    /// Returns whether a session has stored auto-naming state that can be
    /// replayed without generating a new title. Manual workspaces use this
    /// guard to avoid reading their transcript when there is nothing to repair.
    func hasReplayableAutoNamingState(_ session: ClaudeHookSessionRecord?) -> Bool {
        session?.autoNameLastTitle != nil || session?.autoNameInFlightAt != nil
    }

    /// A manual workspace suppresses new title generation, but a stored auto
    /// title still needs the detached pass for transcript-shrink reconciliation
    /// and independently auto-owned panel repair.
    func shouldSpawnDetachedAgentAutoName(
        probe: [String: Any],
        session: ClaudeHookSessionRecord?,
        currentProgress: Int? = nil
    ) -> Bool {
        guard probe["enabled"] as? Bool == true else { return false }
        guard probe["workspace_user_owned"] as? Bool == true else { return true }
        guard hasReplayableAutoNamingState(session) else { return false }
        // One detached worker already owns the store claim. Overlapping Stop
        // hooks must not fork another process while that marker is live.
        if let inFlightAt = session?.autoNameInFlightAt,
           Date().timeIntervalSince1970 - inFlightAt < AutoNamingEngine().config.inFlightExpiry {
            return false
        }
        if session?.autoNameTitleReconciliationGeneration != nil {
            return true
        }
        guard let currentProgress, let session else { return false }
        let observedProgress = max(
            session.autoNameLastLineCount ?? 0,
            max(session.autoNameLastObservedLineCount ?? 0, session.autoNameInFlightObservedLineCount ?? 0)
        )
        if max(0, session.autoNameTitleReconciliationAttemptCount ?? 0)
                >= ClaudeHookSessionStore.maxAutoNameTitleReconciliationAttempts {
            // Generic agents have no explicit compact lifecycle event from
            // which to identify a new epoch. Keep the terminal bound quiet;
            // Claude's explicit compact hook can mint a fresh generation.
            return false
        }
        return currentProgress != observedProgress
    }

    /// Returns the monotonic progress unit used by the detached naming pass.
    /// Hook-message agents use the persisted message sequence; file-backed
    /// agents use a cheap file-size/line metric so a settled manual workspace
    /// does not fork a process on every Stop hook.
    func autoNamingProgressMetric(
        for def: AgentHookDef,
        session: ClaudeHookSessionRecord?,
        sessionId: String,
        transcriptPath: String?,
        cwd: String?,
        env: [String: String],
        fallbackLineCount: Int? = nil
    ) -> Int? {
        guard let source = autoNamingSource(for: def) else { return nil }
        switch source {
        case .hookMessageCache:
            guard let session else { return nil }
            return AutoNamingEngine().hookMessageLineEquivalentCount(
                session.autoNameRecentMessages ?? [],
                totalMessageCount: session.autoNameMessageSequence
            )
        case .codexRollout:
            guard let path = normalizedHookValue(transcriptPath),
                  fallbackLineCount != nil,
                  FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath)
            else { return nil }
            return textFileGrowthMetric(path: path, fallbackLineCount: fallbackLineCount ?? 0)
        case .grokHistory:
            guard let sessionDirectory = grokSessionDirectory(
                cwd: normalizedHookValue(cwd) ?? session?.cwd,
                sessionId: sessionId,
                env: env
            ) else { return nil }
            let historyPath = sessionDirectory
                .appendingPathComponent("chat_history.jsonl", isDirectory: false)
                .path
            guard FileManager.default.fileExists(atPath: historyPath) else { return nil }
            let resolvedFallbackLineCount = fallbackLineCount
                ?? readRecentTextFileLines(path: historyPath, maxBytes: 512 * 1024)?.count
            guard let resolvedFallbackLineCount else { return nil }
            return textFileGrowthMetric(path: historyPath, fallbackLineCount: resolvedFallbackLineCount)
        }
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
        ), probe["enabled"] as? Bool == true else {
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
        let sessionStore = ClaudeHookSessionStore(processEnv: env)
        let spawnToken = normalizedHookValue(env["CMUX_AUTO_NAME_SPAWN_TOKEN"])
        defer {
            if let spawnToken {
                try? sessionStore.releaseAutoNamingSpawn(sessionId: sessionId, token: spawnToken)
            }
        }
        guard let probe = try? client.sendV2(
            method: "workspace.set_auto_title",
            params: ["probe": true, "workspace_id": workspaceId, "panel_id": surfaceId]
        ), probe["enabled"] as? Bool == true else {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.disabled")
            return
        }
        let workspaceUserOwned = probe["workspace_user_owned"] as? Bool == true
        let mapped = try? sessionStore.lookup(sessionId: sessionId)
        guard (try? sessionStore.isCurrent(sessionId: sessionId, workspaceId: workspaceId, surfaceId: surfaceId)) ?? false else {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.stale")
            return
        }
        if workspaceUserOwned, !hasReplayableAutoNamingState(mapped) {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.user-owned-no-replay")
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
        guard let sourceResult else { return }
        if sourceResult.messages.isEmpty {
            guard workspaceUserOwned else { return }
            // Even without extractable user/assistant text, a compaction can
            // change the source high-water. Run the bookkeeping path so the
            // observation is consumed without forking an LLM summarizer.
            runAutoNamingPass(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                lineCount: sourceResult.lineCount,
                sessionStore: sessionStore,
                client: client,
                allowSummarization: false,
                expectedWorkspaceTitle: probe["workspace_title"] as? String,
                expectedPanelTitle: probe["panel_title"] as? String,
                spawnToken: spawnToken,
                telemetryKey: "\(def.name)-hook.auto-name.bookkeeping",
                telemetry: telemetry
            ) { _, _ in nil }
            return
        }

        runMessageBackedAutoName(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            messages: sourceResult.messages,
            lineCount: sourceResult.lineCount,
            sessionStore: sessionStore,
            client: client,
            allowSummarization: !workspaceUserOwned,
            expectedWorkspaceTitle: probe["workspace_title"] as? String,
            expectedPanelTitle: probe["panel_title"] as? String,
            spawnToken: spawnToken,
            telemetryKey: "\(def.name)-hook.auto-name",
            telemetry: telemetry
        ) { engine, outcome in
            let resolution = resolvedSummarizerAgent(
                probe: probe, sessionAgent: def.name, env: env, telemetry: telemetry
            )
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
            return (response: raw, missingOverride: resolution.missingOverride)
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
        allowSummarization: Bool,
        expectedWorkspaceTitle: String? = nil,
        expectedPanelTitle: String? = nil,
        spawnToken: String? = nil,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry,
        rawResponse: (AutoNamingEngine, ClaudeHookSessionStore.AutoNamingBeginOutcome) -> (response: String, missingOverride: String?)?
    ) {
        guard !lines.isEmpty else { return }
        runAutoNamingPass(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lineCount: lineCount,
            sessionStore: sessionStore,
            client: client,
            allowSummarization: allowSummarization,
            expectedWorkspaceTitle: expectedWorkspaceTitle,
            expectedPanelTitle: expectedPanelTitle,
            spawnToken: spawnToken,
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
        allowSummarization: Bool,
        expectedWorkspaceTitle: String? = nil,
        expectedPanelTitle: String? = nil,
        spawnToken: String? = nil,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry,
        rawResponse: (AutoNamingEngine, ClaudeHookSessionStore.AutoNamingBeginOutcome) -> (response: String, missingOverride: String?)?
    ) {
        guard !messages.isEmpty else { return }
        runAutoNamingPass(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lineCount: lineCount,
            sessionStore: sessionStore,
            client: client,
            allowSummarization: allowSummarization,
            expectedWorkspaceTitle: expectedWorkspaceTitle,
            expectedPanelTitle: expectedPanelTitle,
            spawnToken: spawnToken,
            telemetryKey: telemetryKey,
            telemetry: telemetry,
            rawResponse: rawResponse
        )
    }

    /// Services the durable replay obligation created by an explicit Claude
    /// compact event. Returns true whenever pending work exists, including
    /// when another hook currently owns its in-flight claim, so callers never
    /// fall through to throttle/LLM work in the same pass.
    @discardableResult
    func reconcilePendingAutoNamingTitleIfNeeded(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        transcriptLineCount: Int?,
        clearPendingOnConfirmation: Bool,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry
    ) -> Bool {
        let engine = AutoNamingEngine()
        guard let claim = try? sessionStore.claimPendingAutoNamingTitleReconciliation(
            sessionId: sessionId,
            transcriptLineCount: transcriptLineCount,
            now: Date(),
            engine: engine
        ), claim.pending else {
            return false
        }
        if claim.exhausted {
            telemetry.breadcrumb("\(telemetryKey).exhausted")
            return true
        }
        guard let title = claim.title else {
            telemetry.breadcrumb("\(telemetryKey).in-flight")
            return true
        }
        guard (try? sessionStore.isCurrent(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )) ?? false else {
            telemetry.breadcrumb("\(telemetryKey).stale-before-apply")
            try? sessionStore.finishAutoNamingReconciliation(
                sessionId: sessionId,
                compactedLineCount: claim.compactedLineCount,
                confirmedApply: false,
                claimedReconciliationGeneration: claim.generation,
                observationGeneration: claim.observationGeneration,
                clearPendingOnConfirmation: false
            )
            return true
        }
        let applyOutcome = applyAutoNamingTitle(
            title,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            expectedSessionId: sessionId,
            expectedWorkspaceTitle: title,
            expectedPanelTitle: title,
            reconciliationCAS: true,
            clearStatusOnApply: false,
            client: client,
            telemetryKey: telemetryKey,
            telemetry: telemetry
        )
        let confirmedApply = (try? applyOutcome.get())?.targetsResolved == true
        try? sessionStore.finishAutoNamingReconciliation(
            sessionId: sessionId,
            compactedLineCount: claim.compactedLineCount,
            confirmedApply: confirmedApply,
            claimedReconciliationGeneration: claim.generation,
            observationGeneration: claim.observationGeneration,
            clearPendingOnConfirmation: clearPendingOnConfirmation
        )
        return true
    }

    private func runAutoNamingPass(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        lineCount: Int,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        allowSummarization: Bool,
        expectedWorkspaceTitle: String? = nil,
        expectedPanelTitle: String? = nil,
        spawnToken: String? = nil,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry,
        rawResponse: (AutoNamingEngine, ClaudeHookSessionStore.AutoNamingBeginOutcome) -> (response: String, missingOverride: String?)?
    ) {
        let engine = AutoNamingEngine()
        guard let outcome = try? sessionStore.beginAutoNaming(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            transcriptLineCount: lineCount,
            now: Date(),
            engine: engine,
            allowNewTitleGeneration: allowSummarization,
            spawnToken: spawnToken
        ) else { return }
        if outcome.reconciliationExhausted {
            telemetry.breadcrumb("\(telemetryKey).reconcile-exhausted")
            return
        }
        if case .reseedBaseline(let compactedLineCount) = outcome.decision {
            let applyOutcome: Result<(titleApplied: Bool, targetsResolved: Bool, terminalSkip: Bool, targetUnresolved: Bool), CLIError>
            if let lastTitle = outcome.lastTitle {
                if (try? sessionStore.isCurrent(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId
                )) ?? false {
                    applyOutcome = applyAutoNamingTitle(
                        lastTitle,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        expectedSessionId: sessionId,
                        expectedWorkspaceTitle: lastTitle,
                        expectedPanelTitle: lastTitle,
                        reconciliationCAS: true,
                        clearStatusOnApply: false,
                        client: client,
                        telemetryKey: "\(telemetryKey).reconcile",
                        telemetry: telemetry
                    )
                } else {
                    telemetry.breadcrumb("\(telemetryKey).reconcile.stale-before-apply")
                    applyOutcome = .success((titleApplied: false, targetsResolved: false, terminalSkip: false, targetUnresolved: true))
                }
            } else {
                telemetry.breadcrumb("\(telemetryKey).throttled")
                applyOutcome = .success((titleApplied: false, targetsResolved: false, terminalSkip: false, targetUnresolved: false))
            }
            let applied = try? applyOutcome.get()
            let confirmedApply = applied?.targetsResolved == true
            try? sessionStore.finishAutoNamingReconciliation(
                sessionId: sessionId,
                compactedLineCount: compactedLineCount,
                confirmedApply: confirmedApply,
                observationGeneration: outcome.observationGeneration
            )
            return
        }
        guard case .proceed(let baseline) = outcome.decision else {
            telemetry.breadcrumb("\(telemetryKey).throttled")
            return
        }
        guard allowSummarization else {
            telemetry.breadcrumb("\(telemetryKey).user-owned")
            return
        }

        var confirmedTitle: String?
        var baselineConfirmedWithoutTitle = false
        defer {
            try? sessionStore.finishAutoNaming(
                sessionId: sessionId,
                appliedTitle: confirmedTitle,
                baselineLineCount: confirmedTitle != nil || baselineConfirmedWithoutTitle ? baseline : nil,
                baselineConfirmedWithoutTitle: baselineConfirmedWithoutTitle,
                observationGeneration: outcome.observationGeneration,
                now: Date()
            )
        }
        guard let generated = rawResponse(engine, outcome) else {
            telemetry.breadcrumb("\(telemetryKey).llm-failed")
            return
        }
        guard let sanitized = engine.sanitizeResponse(generated.response, currentTitle: nil) else { return }
        guard (try? sessionStore.isCurrent(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )) ?? false else {
            telemetry.breadcrumb("\(telemetryKey).stale-before-apply")
            return
        }
        let applyOutcome = applyAutoNamingTitle(
            sanitized,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            expectedSessionId: sessionId,
            expectedWorkspaceTitle: expectedWorkspaceTitle,
            expectedPanelTitle: expectedPanelTitle,
            client: client,
            telemetryKey: telemetryKey,
            telemetry: telemetry
        )
        switch applyOutcome {
        case .success(let applied):
            if applied.targetsResolved {
                if applied.titleApplied {
                    confirmedTitle = sanitized
                } else if let lastTitle = outcome.lastTitle {
                    confirmedTitle = lastTitle
                } else if applied.terminalSkip {
                    // A terminal target skip (for example, a panel that
                    // disappeared) is resolved without creating a title. Mark
                    // its baseline complete so the same transcript is not
                    // summarized again forever.
                    baselineConfirmedWithoutTitle = true
                }
            }
        case .failure:
            confirmedTitle = nil
        }
        // Re-report a missing override only after the apply, so the app's
        // clear-on-apply doesn't immediately wipe the Settings note.
        if confirmedTitle != nil, let missing = generated.missingOverride {
            reportAutoNamingProblem("not_installed", agent: missing, workspaceId: workspaceId, client: client)
        }
    }

}
