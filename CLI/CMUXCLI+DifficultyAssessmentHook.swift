import CMUXAgentLaunch
import Foundation

/// What the difficulty pass notes about the turn when the `Stop` hook starts,
/// right after it parses its input: before the session store's lock, which
/// the sync `Stop` hook can hold at turn end, and before auto-naming's call,
/// which can run a minute. It reads no transcript content: the hook runs for
/// every cmux Claude user, session priority on or off.
struct ClaudeDifficultyTurnStart {
    /// The reply the `Stop` input carries; `nil` when it carries none, and the
    /// pass then rates nothing.
    var stopReply: String?
    /// With a `stopReply`: the transcript and its byte size at hook start. The
    /// transcript is append-only, so its bytes up to that size are what was on
    /// disk then; a prompt the user sends during naming's call lies past them.
    var transcriptPath: String?
    var transcriptSize: UInt64?

    /// With a reply but no transcript path in the input: `path`, the session
    /// record's, measured now, as soon as it is known.
    func withTranscriptFallback(_ path: String?) -> ClaudeDifficultyTurnStart {
        guard stopReply != nil, transcriptPath == nil, let path else { return self }
        return ClaudeDifficultyTurnStart(
            stopReply: stopReply,
            transcriptPath: path,
            transcriptSize: RecentTextFileLines.byteSize(path: path)
        )
    }
}

extension CMUXCLI {
    /// Notes what the difficulty pass needs from the turn as soon as the hook
    /// input is parsed: with the `Stop` input's reply, the input's transcript
    /// path and its size, from `stat(2)`. Without a path in the input, the
    /// session record's is measured once it is looked up
    /// (``ClaudeDifficultyTurnStart/withTranscriptFallback(_:)``).
    func claudeDifficultyTurnStart(parsedInput: ClaudeHookParsedInput) -> ClaudeDifficultyTurnStart {
        // The raw input: the parsed `object` cuts `last_assistant_message` to 240 characters.
        guard let reply = DifficultyAssessmentEngine.stopReply(fromHookInput: parsedInput.rawObject) else {
            return ClaudeDifficultyTurnStart()
        }
        let transcriptPath = parsedInput.transcriptPath
        return ClaudeDifficultyTurnStart(
            stopReply: reply,
            transcriptPath: transcriptPath,
            transcriptSize: transcriptPath.flatMap { RecentTextFileLines.byteSize(path: $0) }
        )
    }

    /// Drives one automatic task-difficulty pass for a Claude session at turn
    /// end. Independent of auto-naming: it probes the app on its own, never
    /// throws, and every failure path is silent so it cannot affect the hook's
    /// exit status or the naming pass that runs before it. `turnStart` is what
    /// ``claudeDifficultyTurnStart(parsedInput:)`` noted when the hook started.
    func runClaudeDifficultyAssessmentHook(
        parsedInput: ClaudeHookParsedInput,
        mappedSession: ClaudeHookSessionRecord?,
        turnStart: ClaudeDifficultyTurnStart,
        workspaceId: String,
        surfaceId: String,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry
    ) {
        guard let sessionId = parsedInput.sessionId else { return }
        // Without the reply in the `Stop` input (a Claude Code that does not pass
        // `last_assistant_message`) the turn is not rated: the transcript gets the
        // reply only after this async hook starts, and nothing signals when.
        guard let stopReply = turnStart.stopReply else {
            telemetry.breadcrumb("claude-hook.difficulty.no-reply")
            return
        }
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

        // This turn's prompt: the last user message in the transcript as it was at hook start.
        // A transcript now shorter than then was truncated or replaced: nothing is rated.
        guard let transcriptPath = turnStart.transcriptPath, let size = turnStart.transcriptSize,
              let lines = readRecentTextFileLines(path: transcriptPath, maxBytes: 512 * 1024, endingAt: size),
              let excerpt = DifficultyAssessmentEngine.excerpt(
                  from: AutoNamingEngine().extractMessages(fromTranscriptLines: lines),
                  stopReply: stopReply
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
        // Checked again after the call: another session may have taken the pane
        // meanwhile (`/clear` starts one), and this one's verdict must not set the
        // workspace it now runs in. No turn id: this session's own next prompt
        // during the call does not void its rating.
        guard shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            sessionId: sessionId,
            turnId: nil,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            telemetry: telemetry
        ) else {
            telemetry.breadcrumb("claude-hook.difficulty.stale-after-rating")
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
}
