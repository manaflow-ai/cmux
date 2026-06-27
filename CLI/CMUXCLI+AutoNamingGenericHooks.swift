import Foundation
import CryptoKit

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
        surfaceId: String,
        engine: AutoNamingEngine = AutoNamingEngine()
    ) -> [AutoNamingTranscriptMessage] {
        guard usesHookMessageCacheForAutoNaming(def),
              let object = parsedInput.rawObject ?? parsedInput.object else {
            return []
        }
        guard let probe = try? client.sendV2(
            method: "workspace.set_auto_title",
            params: autoNamingProbeParams(workspaceId: workspaceId, surfaceId: surfaceId)
        ), autoNamingProbeHasWritableTarget(probe) else {
            return []
        }
        return engine.extractHookMessages(fromPayloadObjects: [object])
    }

    func autoNamingMessageBatchKey(for def: AgentHookDef, parsedInput: ClaudeHookParsedInput) -> String? {
        guard usesHookMessageCacheForAutoNaming(def),
              let object = parsedInput.rawObject ?? parsedInput.object,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        let sessionId = normalizedHookValue(parsedInput.sessionId) ?? ""
        let turnId = normalizedHookValue(parsedInput.turnId) ?? ""
        return "\(def.name)\u{1F}\(sessionId)\u{1F}\(turnId)\u{1F}\(autoNamingBatchFingerprint(data))"
    }

    private func autoNamingBatchFingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
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
        let telemetryKey = "\(def.name)-hook.auto-name"
        guard let probe = probeAutoNaming(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            agent: def.name,
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
        let mapped = try? sessionStore.lookup(sessionId: sessionId)
        guard (try? sessionStore.isCurrent(sessionId: sessionId, workspaceId: workspaceId, surfaceId: surfaceId)) ?? false else {
            telemetry.breadcrumb("\(telemetryKey).stale")
            return
        }

        let engine = AutoNamingEngine()
        let sourceResult: (messages: [AutoNamingTranscriptMessage], lineCount: Int, diagnostic: String?)? = {
            switch source {
            case .codexRollout:
                return nil
            case .grokHistory:
                let cwd = normalizedHookValue(optionValue(commandArgs, name: "--cwd")) ?? mapped?.cwd
                guard let sessionURL = grokSessionDirectory(cwd: cwd, sessionId: sessionId, env: env) else {
                    telemetry.breadcrumb("\(telemetryKey).session-directory-missing")
                    reportAutoNamingProblem("extraction_failed", agent: def.name, workspaceId: workspaceId, client: client)
                    return nil
                }
                let historyURL = sessionURL.appendingPathComponent("chat_history.jsonl", isDirectory: false)
                guard let lines = readRecentTextFileLines(path: historyURL.path, maxBytes: 512 * 1024),
                      !lines.isEmpty else {
                    telemetry.breadcrumb("\(telemetryKey).transcript-unreadable")
                    reportAutoNamingProblem("extraction_failed", agent: def.name, workspaceId: workspaceId, client: client)
                    return nil
                }
                let lineCount = textFileGrowthMetric(path: historyURL.path, fallbackLineCount: lines.count)
                let extraction = engine.extractGrokHistory(fromChatHistoryLines: lines)
                return (extraction.messages, lineCount, extraction.diagnosticSummary)
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
                    ),
                    nil
                )
            }
        }()
        if let diagnostic = sourceResult?.diagnostic {
            telemetry.breadcrumb("\(telemetryKey).extraction.\(diagnostic)")
        }
        guard let sourceResult else {
            telemetry.breadcrumb("\(telemetryKey).extraction-empty")
            if source != .hookMessageCache {
                reportAutoNamingProblem("extraction_failed", agent: def.name, workspaceId: workspaceId, client: client)
            }
            return
        }

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
            summarizerAgent: resolution.agent,
            missingOverride: resolution.missingOverride,
            currentTitle: currentTitle,
            panelTitleTarget: panelTitleTarget,
            telemetryKey: telemetryKey,
            telemetry: telemetry
        ) { engine, _ in
            guard let context = engine.buildContext(from: sourceResult.messages) else {
                telemetry.breadcrumb("\(telemetryKey).extraction-empty")
                if source != .hookMessageCache {
                    reportAutoNamingProblem("extraction_failed", agent: def.name, workspaceId: workspaceId, client: client)
                }
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
                reportAutoNamingProblem("failed", agent: resolution.agent, workspaceId: workspaceId, client: client)
                return (nil, true)
            }
            return (raw, true)
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
        summarizerAgent: String,
        missingOverride: String?,
        currentTitle: String?,
        panelTitleTarget: Bool,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry,
        rawResponse: (AutoNamingEngine, ClaudeHookSessionStore.AutoNamingBeginOutcome) -> (raw: String?, countsTowardBackoff: Bool)
    ) {
        guard !lines.isEmpty else { return }
        runAutoNamingPass(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lineCount: lineCount,
            sessionStore: sessionStore,
            client: client,
            summarizerAgent: summarizerAgent,
            missingOverride: missingOverride,
            currentTitle: currentTitle,
            panelTitleTarget: panelTitleTarget,
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
        summarizerAgent: String,
        missingOverride: String?,
        currentTitle: String?,
        panelTitleTarget: Bool,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry,
        rawResponse: (AutoNamingEngine, ClaudeHookSessionStore.AutoNamingBeginOutcome) -> (raw: String?, countsTowardBackoff: Bool)
    ) {
        runAutoNamingPass(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lineCount: lineCount,
            sessionStore: sessionStore,
            client: client,
            summarizerAgent: summarizerAgent,
            missingOverride: missingOverride,
            currentTitle: currentTitle,
            panelTitleTarget: panelTitleTarget,
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
        summarizerAgent: String,
        missingOverride: String?,
        currentTitle: String?,
        panelTitleTarget: Bool,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry,
        rawResponse: (AutoNamingEngine, ClaudeHookSessionStore.AutoNamingBeginOutcome) -> (raw: String?, countsTowardBackoff: Bool)
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
        let rawResponseResult = rawResponse(engine, outcome)
        guard let rawResponse = rawResponseResult.raw else {
            countFailure = rawResponseResult.countsTowardBackoff
            if countFailure {
                telemetry.breadcrumb("\(telemetryKey).llm-failed")
            }
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
                agent: summarizerAgent,
                client: client,
                panelTitleTarget: panelTitleTarget,
                telemetryKey: telemetryKey,
                telemetry: telemetry
            )
            confirmedTitle = applyResult.confirmedTitle
            countFailure = applyResult.countsTowardBackoff
        } else {
            confirmedTitle = confirmAutoNamingSuccess(
                workspaceId: workspaceId,
                agent: summarizerAgent,
                client: client,
                telemetryKey: telemetryKey,
                telemetry: telemetry
            ) ? action.title : nil
        }
        // Re-report a missing override only after the fallback pass succeeds,
        // so clear-on-apply does not immediately wipe the Settings note.
        if confirmedTitle != nil, let missing = missingOverride {
            reportAutoNamingProblem("not_installed", agent: missing, workspaceId: workspaceId, client: client)
        }
    }

    func autoNamingSanitizedAction(
        engine: AutoNamingEngine,
        rawResponse: String,
        currentTitle: String?,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry
    ) -> (title: String, shouldApply: Bool)? {
        switch engine.sanitizeResponseOutcome(rawResponse, currentTitle: currentTitle) {
        case .title(let title):
            return (title, true)
        case .unchanged(let title):
            telemetry.breadcrumb("\(telemetryKey).unchanged")
            return (title, true)
        case .unusable:
            telemetry.breadcrumb("\(telemetryKey).unusable-response")
            return nil
        }
    }

    func confirmAutoNamingSuccess(
        workspaceId: String,
        agent: String,
        client: SocketClient,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry
    ) -> Bool {
        do {
            _ = try client.sendV2(method: "workspace.set_auto_title", params: [
                "success": true,
                "workspace_id": workspaceId
            ])
            return true
        } catch {
            telemetry.breadcrumb("\(telemetryKey).success-confirm-failed")
            reportAutoNamingProblem("apply_failed", agent: agent, workspaceId: workspaceId, client: client)
            return false
        }
    }

    func applyAutoNamingTitle(
        _ title: String,
        workspaceId: String,
        surfaceId: String,
        agent: String,
        client: SocketClient,
        panelTitleTarget: Bool,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry
    ) -> (confirmedTitle: String?, countsTowardBackoff: Bool) {
        let payload: [String: Any]
        do {
            payload = try client.sendV2(method: "workspace.set_auto_title", params: [
                "workspace_id": workspaceId,
                "panel_id": surfaceId,
                "panel_only_if_multiple": true,
                "panel_title_target": panelTitleTarget,
                "title": title
            ])
        } catch {
            telemetry.breadcrumb("\(telemetryKey).socket-failed")
            reportAutoNamingProblem("apply_failed", agent: agent, workspaceId: workspaceId, client: client)
            return (nil, true)
        }
        if payload["workspace_applied"] as? Bool == true || payload["panel_applied"] as? Bool == true {
            telemetry.breadcrumb("\(telemetryKey).applied")
            return (title, false)
        }
        telemetry.breadcrumb("\(telemetryKey).rejected")
        return (nil, false)
    }
}
