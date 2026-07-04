import Foundation

import CmuxSettings

extension CMUXCLI {
    /// Resolves which agent should actually run the summarization for one
    /// naming pass, honoring the user's `automation.autoNamingAgent` override
    /// (carried on the socket probe response as `summarizer_agent`).
    ///
    /// `auto` / the session's own agent / an unsupported or uninstalled choice
    /// all collapse to `sessionAgent`, so naming never breaks. When a supported
    /// override is selected but its binary is missing, the chosen agent is
    /// returned as `missingOverride` so the caller can surface a Settings note.
    func resolvedSummarizerAgent(
        probe: [String: Any],
        sessionAgent: String,
        env: [String: String],
        telemetry: CLISocketSentryTelemetry
    ) -> (agent: String, missingOverride: String?) {
        // Pure decision (unit-tested in CmuxSettings); the CLI only supplies the
        // binary-availability probe and emits telemetry.
        let decision = AutoNamingAgentCatalog.resolveSummarizer(
            chosen: probe["summarizer_agent"] as? String,
            sessionAgent: sessionAgent,
            isInstalled: { summarizerBinaryAvailable(agent: $0, env: env) }
        )
        if let missing = decision.missingOverride {
            telemetry.breadcrumb("auto-name.summarizer-fallback.\(missing)")
        } else if decision.agent != sessionAgent {
            telemetry.breadcrumb("auto-name.summarizer-override.\(decision.agent)")
        }
        return (decision.agent, decision.missingOverride)
    }

    /// True when the chosen summarizer agent's binary can be resolved using the
    /// same logic the summarizers themselves use (so we never fall back when the
    /// binary would actually run).
    func summarizerBinaryAvailable(agent: String, env: [String: String]) -> Bool {
        switch agent {
        case "claude":
            let customPath = env["CMUX_CUSTOM_CLAUDE_PATH"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !customPath.isEmpty,
               FileManager.default.isExecutableFile(atPath: customPath),
               !isCmuxClaudeWrapper(at: customPath) {
                return true
            }
            return resolveClaudeExecutable(searchPath: env["PATH"]) != nil
        case "codex":
            return resolveCodexExecutable(searchPath: env["PATH"]) != nil
        default:
            guard let def = CMUXCLI.agentDef(named: agent) else { return false }
            return resolveExecutableInSearchPath(def.binaryName, searchPath: env["PATH"]) != nil
        }
    }

    /// Single entry point that runs the summarizer for `summarizerAgent` and
    /// returns its raw response (or nil on any failure). Transcript parsing
    /// stays in the per-agent hook entry points; this only owns the
    /// binary-invocation + per-agent environment scrubbing, so a Claude session
    /// can be summarized by Codex (or vice-versa) without leaking the wrong env.
    func summarize(
        summarizerAgent agent: String,
        prompt: String,
        env: [String: String],
        timeout: TimeInterval,
        telemetry: CLISocketSentryTelemetry
    ) -> String? {
        switch agent {
        case "claude":
            return summarizeWithClaude(prompt: prompt, env: env, timeout: timeout)
        case "codex":
            return summarizeWithCodex(prompt: prompt, env: env, timeout: timeout)
        default:
            guard let def = CMUXCLI.agentDef(named: agent) else { return nil }
            return runAutoNamingSummarizer(
                def: def,
                prompt: prompt,
                env: env,
                timeout: timeout,
                telemetry: telemetry
            )
        }
    }

    /// Best-effort report of a naming problem to the app so it can surface a
    /// message in Settings. Never touches the workspace/tab title; if the socket
    /// call fails, naming simply stays silent.
    func reportAutoNamingProblem(
        _ category: String,
        agent: String,
        workspaceId: String,
        client: SocketClient
    ) {
        _ = try? client.sendV2(method: "workspace.set_auto_title", params: [
            "failure": category,
            "agent": agent,
            "workspace_id": workspaceId
        ])
    }

    func clearPersistedAgentSessionTitle(
        workspaceId: String,
        excludingSessionId: String,
        excludingPid: Int?,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry
    ) {
        let workspaceStillOwned = (try? sessionStore.hasOtherLiveSession(
            workspaceId: workspaceId,
            excludingSessionId: excludingSessionId
        )) != false
        guard !workspaceStillOwned else {
            telemetry.breadcrumb("\(telemetryKey).clear-title.other-session-live")
            return
        }
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "clear_auto": true
        ]
        if let excludingPid {
            params["excluding_pid"] = String(excludingPid)
        }
        guard let payload = try? client.sendV2(method: "workspace.set_auto_title", params: params) else {
            telemetry.breadcrumb("\(telemetryKey).clear-title.socket-failed")
            return
        }
        if payload["workspace_cleared"] as? Bool == true {
            telemetry.breadcrumb("\(telemetryKey).clear-title.cleared")
        } else {
            telemetry.breadcrumb("\(telemetryKey).clear-title.no-op")
        }
    }

    /// Persists an exited agent session's last auto title onto its workspace,
    /// but only when no other live session still owns that workspace.
    ///
    /// The live-session guard lives here, not at the call sites, so every
    /// lifecycle entrypoint (Claude and the generic/PI hooks) gets it: exit
    /// ordering across sibling panes is nondeterministic and `SessionEnd` /
    /// `isCurrent()` are per-surface (see issue #5908), so an exiting split can
    /// otherwise stamp its stale title over the workspace while a sibling
    /// session in another surface is still alive and owns the auto title. The
    /// guard treats any sibling with a live process as owning the workspace,
    /// not only actively-running ones — an idle / needs-input split is the
    /// common case and still owns the title.
    ///
    /// The guard fails closed: if the session store can't be read we cannot rule
    /// out a live sibling, so the persist is skipped rather than risk clobbering
    /// its title. A transcript-derived title is a *new* auto-naming action, so it
    /// is tagged `auto_derived` and the app rejects it when auto-naming is
    /// disabled; a title cmux already applied is only preserved and persists
    /// regardless of the setting.
    ///
    /// This CLI store only tracks the exiting agent's own sessions, so it cannot
    /// see a live session from a *different* agent (each agent keeps its own hook
    /// store) sharing the workspace. `excludingPid` carries the exiting agent's
    /// process id so the app can additionally reject the persist when another
    /// agent's process still owns the shared workspace title.
    func persistAgentSessionTitleAfterExit(
        _ exitTitle: AgentSessionExitTitle?,
        workspaceId: String,
        excludingSessionId: String,
        excludingPid: Int?,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry
    ) {
        guard let exitTitle else { return }
        let workspaceStillOwned = (try? sessionStore.hasOtherLiveSession(
            workspaceId: workspaceId,
            excludingSessionId: excludingSessionId
        )) != false
        guard !workspaceStillOwned else {
            telemetry.breadcrumb("\(telemetryKey).persist-title.other-session-live")
            return
        }
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "title": exitTitle.title,
            "persist_after_exit": true
        ]
        if exitTitle.derivedFromTranscript {
            params["auto_derived"] = true
        }
        if let excludingPid {
            params["excluding_pid"] = String(excludingPid)
        }
        guard let payload = try? client.sendV2(method: "workspace.set_auto_title", params: params) else {
            telemetry.breadcrumb("\(telemetryKey).persist-title.socket-failed")
            return
        }
        if payload["workspace_applied"] as? Bool == true {
            telemetry.breadcrumb("\(telemetryKey).persist-title.applied")
        } else {
            telemetry.breadcrumb("\(telemetryKey).persist-title.rejected")
        }
    }

    /// A title to re-apply to a workspace when an agent session exits, plus
    /// whether it was derived from the agent transcript (a *new* auto-naming
    /// action that must honor the opt-in) versus a title cmux already applied
    /// during the session (which is only being preserved).
    struct AgentSessionExitTitle {
        let title: String
        let derivedFromTranscript: Bool
    }

    func agentSessionExitTitle(
        agent: String,
        record: ClaudeHookSessionRecord
    ) -> AgentSessionExitTitle? {
        if let applied = normalizedAgentSessionExitTitle(record.autoNameLastTitle) {
            return AgentSessionExitTitle(title: applied, derivedFromTranscript: false)
        }
        guard agent == "claude",
              let derived = latestClaudeTranscriptTitle(path: record.transcriptPath) else {
            return nil
        }
        return AgentSessionExitTitle(title: derived, derivedFromTranscript: true)
    }

    private func latestClaudeTranscriptTitle(path: String?) -> String? {
        guard let path = normalizedHookValue(path),
              let lines = readRecentTextFileLines(path: path, maxBytes: 512 * 1024) else {
            return nil
        }
        for line in lines.reversed() {
            if let title = claudeTranscriptTitle(in: line) {
                return title
            }
        }
        return nil
    }

    private func claudeTranscriptTitle(in line: String) -> String? {
        guard line.contains(#""ai-title""#),
              let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "ai-title" else {
            return nil
        }
        return normalizedAgentSessionExitTitle(object["aiTitle"] as? String)
    }

    private func normalizedAgentSessionExitTitle(_ title: String?) -> String? {
        let collapsed = title?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(120))
    }

    // MARK: - Per-agent summarizer invocations (moved verbatim from the hooks)

    private func summarizeWithClaude(
        prompt: String,
        env: [String: String],
        timeout: TimeInterval
    ) -> String? {
        let policy = AutoNamingEnvironmentPolicy()
        let customPath = env["CMUX_CUSTOM_CLAUDE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let executable: String? = {
            var isDirectory = ObjCBool(false)
            if !customPath.isEmpty,
               FileManager.default.fileExists(atPath: customPath, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: customPath),
               !isCmuxClaudeWrapper(at: customPath) {
                return customPath
            }
            return resolveClaudeExecutable(searchPath: env["PATH"])
        }()
        guard let executable else { return nil }
        return runAutoNamingSummarizer(
            executable: executable,
            arguments: [
                "-p",
                "--model", policy.claudeModel(from: env),
                "--tools", "",
                "--disable-slash-commands",
                "--no-session-persistence",
                "--strict-mcp-config",
                "--mcp-config", "{}"
            ],
            prompt: prompt,
            environment: policy.summarizerEnvironment(from: env),
            timeout: timeout
        )
    }

    private func summarizeWithCodex(
        prompt: String,
        env: [String: String],
        timeout: TimeInterval
    ) -> String? {
        guard let executable = resolveCodexExecutable(searchPath: env["PATH"]) else { return nil }
        let policy = AutoNamingEnvironmentPolicy()
        var summarizerEnv = policy.codexSummarizerEnvironment(from: env)
        summarizerEnv["CMUX_CODEX_HOOKS_DISABLED"] = "1"
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-autoname-\(UUID().uuidString).txt")
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-autoname-cwd-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: outputFile)
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        guard runAutoNamingSummarizer(
            executable: executable,
            arguments: [
                "exec",
                "-c", "default_tools_enabled=false",
                "-c", "tools={}",
                "-c", "mcp_servers={}",
                "-c", "web_search=false",
                "-c", "approval_policy=never",
                "-c", "shell_environment_policy.inherit=none",
                "--skip-git-repo-check",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "--sandbox", "read-only",
                "--cd", workingDirectory.path,
                "--output-last-message", outputFile.path,
                "-"
            ],
            prompt: prompt,
            environment: summarizerEnv,
            timeout: timeout
        ) != nil else {
            return nil
        }
        return (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
    }
}
