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
