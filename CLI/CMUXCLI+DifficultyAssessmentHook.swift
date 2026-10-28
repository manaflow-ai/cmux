import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    /// Drives one automatic task-difficulty pass for a Claude session at turn
    /// end. Independent of auto-naming: it probes the app on its own, never
    /// throws, and every failure path is silent so it cannot affect the hook's
    /// exit status or the naming pass that runs before it.
    func runClaudeDifficultyAssessmentHook(
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
            method: "session_priority.set",
            params: ["probe": true, "workspace_id": workspaceId]
        ), probe["enabled"] as? Bool == true else {
            telemetry.breadcrumb("claude-hook.difficulty.disabled")
            return
        }
        guard probe["manual"] as? Bool != true, probe["override_present"] as? Bool != true else {
            telemetry.breadcrumb("claude-hook.difficulty.overridden")
            return
        }

        let claudePid = mappedSession?.pid ?? claudeAgentPID(from: env)
        guard !shouldSuppressNestedAgentVisibleMutations(currentAgentPID: claudePid, env: env) else {
            telemetry.breadcrumb("claude-hook.difficulty.nested-suppressed")
            return
        }
        guard shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            telemetry: telemetry
        ) else {
            telemetry.breadcrumb("claude-hook.difficulty.stale")
            return
        }

        guard let transcriptPath = parsedInput.transcriptPath ?? mappedSession?.transcriptPath,
              let lines = readRecentTextFileLines(path: transcriptPath, maxBytes: 512 * 1024),
              !lines.isEmpty else { return }
        let messages = AutoNamingEngine().extractMessages(fromTranscriptLines: lines)
        guard let excerpt = DifficultyAssessmentEngine.excerpt(from: messages) else { return }
        guard !excerpt.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !excerpt.assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            telemetry.breadcrumb("claude-hook.difficulty.empty")
            return
        }

        guard let decision = try? sessionStore.beginDifficultyAssessment(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            now: Date()
        ), decision == .proceed else {
            telemetry.breadcrumb("claude-hook.difficulty.throttled")
            return
        }

        var applied: ClaudeSessionDifficulty?
        defer {
            try? sessionStore.finishDifficultyAssessment(sessionId: sessionId, result: applied, now: Date())
        }

        let prompt = DifficultyAssessmentEngine.buildPrompt(
            lastUserMessage: excerpt.user,
            lastAssistantMessage: excerpt.assistant
        )
        // `summarize` scrubs the environment itself (and needs the raw one to
        // honor CMUX_CUSTOM_CLAUDE_PATH), exactly as the auto-name pass does.
        guard let raw = summarize(
            summarizerAgent: "claude",
            prompt: prompt,
            env: env,
            timeout: DifficultyAssessmentConfig.llmTimeout,
            telemetry: telemetry
        ) else {
            telemetry.breadcrumb("claude-hook.difficulty.llm-failed")
            return
        }
        guard let difficulty = DifficultyAssessmentEngine.parse(raw) else {
            telemetry.breadcrumb("claude-hook.difficulty.unparsed")
            return
        }
        guard (try? client.sendV2(
            method: "session_priority.set",
            params: ["workspace_id": workspaceId, "difficulty": difficulty.rawValue, "source": "auto"]
        )) != nil else {
            telemetry.breadcrumb("claude-hook.difficulty.send-failed")
            return
        }
        applied = difficulty
        telemetry.breadcrumb("claude-hook.difficulty.applied")
    }
}
