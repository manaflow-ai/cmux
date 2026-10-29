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
        // Left alone for `--effort`, a launch variable, or a `/effort` cmux saw.
        // An app that predates the key leaves it out; only `false` skips.
        guard probe["adjustable"] as? Bool != false else {
            telemetry.breadcrumb("claude-hook.difficulty.not-adjustable")
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

        // The raw input: the parsed `object` cuts `last_assistant_message` to 240 characters.
        guard let transcriptPath = parsedInput.transcriptPath ?? mappedSession?.transcriptPath,
              let excerpt = claudeDifficultyTurnExcerpt(
                  transcriptPath: transcriptPath,
                  stopReply: DifficultyAssessmentEngine.stopReply(fromHookInput: parsedInput.rawObject),
                  telemetry: telemetry
              ) else { return }

        // Not the hook session store: `SessionEnd` removes that record on every
        // Claude restart, including the one a rating causes.
        let assessments = ClaudeDifficultyAssessmentStore(processEnv: env)
        guard let start = try? assessments.begin(sessionId: sessionId, now: Date()),
              start.decision == .proceed else {
            telemetry.breadcrumb("claude-hook.difficulty.throttled")
            return
        }

        var verdict: ClaudeSessionDifficulty?
        defer {
            try? assessments.finish(sessionId: sessionId, verdict: verdict, now: Date())
        }

        let prompt = DifficultyAssessmentEngine.buildPrompt(
            lastUserMessage: excerpt.user,
            lastAssistantMessage: excerpt.assistant
        )
        // `summarize` scrubs the environment itself (and needs the raw one to
        // honor CMUX_CUSTOM_CLAUDE_PATH), exactly as the auto-name pass does.
        // Always Claude, whatever `automation.autoNamingAgent` picks for naming.
        guard let raw = summarize(
            summarizerAgent: "claude",
            prompt: prompt,
            env: DifficultyAssessmentEngine.classifierEnvironment(from: env),
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
        verdict = difficulty

        let current = (probe["difficulty_auto"] as? String).flatMap(ClaudeSessionDifficulty.init(rawValue:))
        guard let send = DifficultyAssessmentEngine.verdictToSend(
            new: difficulty,
            current: current,
            previous: start.previousVerdict
        ) else {
            telemetry.breadcrumb(difficulty == current ? "claude-hook.difficulty.unchanged" : "claude-hook.difficulty.damped")
            return
        }
        guard (try? client.sendV2(
            method: "session_priority.set",
            params: ["workspace_id": workspaceId, "difficulty": send.rawValue, "source": "auto"]
        )) != nil else {
            telemetry.breadcrumb("claude-hook.difficulty.send-failed")
            return
        }
        telemetry.breadcrumb("claude-hook.difficulty.applied")
    }

    /// This turn's last user message and its reply, or `nil` when there is
    /// nothing to rate.
    ///
    /// The reply is the one the `Stop` input carries. Without it, the reply is
    /// read from the transcript, which Claude Code writes just after this async
    /// hook starts: the transcript is read again every 200 ms, for at most
    /// 5 seconds, until an assistant message follows the last user message. A
    /// reply that never comes skips the turn, so a prompt is never rated with
    /// an earlier turn's reply.
    private func claudeDifficultyTurnExcerpt(
        transcriptPath: String,
        stopReply: String?,
        telemetry: CLISocketSentryTelemetry
    ) -> (user: String, assistant: String)? {
        let deadline = Date().addingTimeInterval(DifficultyAssessmentConfig.replyWait)
        while true {
            // `extractMessages` drops blank messages, so an excerpt is never blank.
            guard let lines = readRecentTextFileLines(path: transcriptPath, maxBytes: 512 * 1024) else { return nil }
            let messages = AutoNamingEngine().extractMessages(fromTranscriptLines: lines)
            if let stopReply {
                return DifficultyAssessmentEngine.excerpt(from: messages, stopReply: stopReply)
            }
            guard messages.contains(where: { $0.role == "user" }) else { return nil }
            if let excerpt = DifficultyAssessmentEngine.excerpt(from: messages) { return excerpt }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                telemetry.breadcrumb("claude-hook.difficulty.no-reply")
                return nil
            }
            Thread.sleep(forTimeInterval: min(DifficultyAssessmentConfig.replyPollInterval, remaining))
        }
    }
}
