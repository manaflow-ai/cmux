import Foundation

/// Resolves Claude configuration directories that may have moved between cmux-managed auth roots.
public struct ClaudeConfigDirectoryPath: Sendable {
    private init() {}

    /// Returns the preferred on-disk Claude config path for a captured launch environment value.
    ///
    /// Legacy cmux auth directories under `~/.subrouter/codex/claude` are mapped to the newer
    /// `~/.codex-accounts/claude` location when the corresponding account directory exists.
    public static func preferredPath(
        _ rawPath: String,
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawPath }

        let standardized = ((trimmed as NSString).expandingTildeInPath as NSString).standardizingPath
        let home = ((homeDirectory as NSString).expandingTildeInPath as NSString).standardizingPath
        let legacyRoot = ((home as NSString).appendingPathComponent(".subrouter/codex/claude") as NSString).standardizingPath
        guard standardized == legacyRoot || standardized.hasPrefix(legacyRoot + "/") else { return standardized }

        let accountRoot = ((home as NSString).appendingPathComponent(".codex-accounts/claude") as NSString).standardizingPath
        let candidate = accountRoot + String(standardized.dropFirst(legacyRoot.count))
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory) && isDirectory.boolValue
            ? candidate
            : standardized
    }

    /// Returns the Claude config directory that holds a session transcript.
    ///
    /// Claude writes transcripts to `<config>/projects/<encoded-cwd>/<session>.jsonl`
    /// (subagent transcripts nest further below the project directory), so the
    /// config directory is the path before the last `projects` component.
    /// Returns nil for a relative path or one that is not below a project directory.
    public static func configDirectory(ofTranscriptPath transcriptPath: String?) -> String? {
        guard let trimmed = transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let standardized = ((trimmed as NSString).expandingTildeInPath as NSString).standardizingPath
        guard standardized.hasPrefix("/"), standardized.hasSuffix(".jsonl") else { return nil }
        let components = standardized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let projectsIndex = components.lastIndex(of: "projects"),
              projectsIndex > 0,
              projectsIndex + 2 < components.count else {
            return nil
        }
        return "/" + components[..<projectsIndex].joined(separator: "/")
    }
}

/// Selects the non-secret launch environment values that are safe to replay when restoring agents.
public struct AgentLaunchEnvironmentPolicy: Sendable {
    /// Creates a launch environment policy.
    public init() {}

    private static let hermesAgentEnvironmentKeys: Set<String> = [
        "CUSTOM_BASE_URL",
        "HERMES_CODEX_BASE_URL",
    ]

    /// Keys campfire manages itself and must not inherit from a captured Pi
    /// environment. Replaying a captured PI_PACKAGE_DIR would pin a resumed
    /// campfire to the previous binary's extracted asset cache
    /// (version+fingerprint keyed) after an upgrade, and replaying
    /// PI_CODING_AGENT_SESSION_DIR would let the embedded Pi runtime resolve
    /// session state under the user's Pi session root instead of the Campfire
    /// root that cmux's scanner uses (`CAMPFIRE_CODING_AGENT_SESSION_DIR` /
    /// `CAMPFIRE_CODING_AGENT_DIR`). Both are dropped for campfire resumes
    /// specifically; pi/omp keep them (Nix installs and custom Pi session
    /// roots rely on them).
    private static let campfireManagedEnvironmentKeys: Set<String> = [
        "PI_CODING_AGENT_SESSION_DIR",
        "PI_PACKAGE_DIR",
    ]

    /// Where OpenCode finds its config, sessions database and state, beyond
    /// `OPENCODE_CONFIG_DIR`. OpenCode reads `OPENCODE_CONFIG_DIR`, then
    /// `XDG_CONFIG_HOME/opencode`; `OPENCODE_DB`, then
    /// `XDG_DATA_HOME/opencode/opencode.db`; `OPENCODE_CONFIG` as one more
    /// config file; and `XDG_STATE_HOME/opencode`. A resumed session needs the
    /// same roots or its session is not found. The XDG roots apply to every
    /// program, so they replay only for OpenCode launches, and every one of
    /// these replays only as an absolute path: a relative root would resolve
    /// against whatever directory the restored pane starts in.
    private static let openCodeLocationEnvironmentKeys: Set<String> = [
        "OPENCODE_CONFIG",
        "OPENCODE_DB",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
    ]

    private static let safeEnvironmentKeys: Set<String> = [
        // AMP_API_KEY is intentionally NOT allowlisted: it's a secret.
        // Amp resolves auth from ~/.config/amp/settings.json on resume.
        "AMP_LOG_FILE",
        "AMP_LOG_LEVEL",
        "AMP_SETTINGS_FILE",
        "AMP_URL",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "CAMPFIRE_CODING_AGENT_DIR",
        "CAMPFIRE_CODING_AGENT_SESSION_DIR",
        "CAMPFIRE_RELAY_URL",
        "CLAUDE_CONFIG_DIR",
        // Selects the directory holding Cursor's cli-config.json and approval policy.
        "CURSOR_CONFIG_DIR",
        // Selects the directory holding Claude Code's .credentials.json. A path, not a secret,
        // so restoring it keeps a restored agent on the account it launched with.
        "CLAUDE_SECURESTORAGE_CONFIG_DIR",
        "CMUX_CUSTOM_CLAUDE_PATH",
        "CMUX_CUSTOM_AMP_PATH",
        "CMUX_CUSTOM_CODEX_PATH",
        "CMUX_CUSTOM_ANTIGRAVITY_PATH",
        "CMUX_ROVODEV_SESSIONS_DIR",
        "CODEX_HOME",
        "CODEBUDDY_BASE_URL",
        "CODEBUDDY_CONFIG_DIR",
        "CODEBUDDY_ENV_FILE",
        "CODEBUDDY_INTERNET_ENVIRONMENT",
        "CODEBUDDY_MODEL",
        "CODEBUDDY_SMALL_FAST_MODEL",
        "COPILOT_GH_HOST",
        "COPILOT_HOME",
        "COPILOT_MODEL",
        "COPILOT_OFFLINE",
        "COPILOT_PROVIDER_BASE_URL",
        "COPILOT_PROVIDER_MAX_OUTPUT_TOKENS",
        "COPILOT_PROVIDER_MAX_PROMPT_TOKENS",
        "COPILOT_PROVIDER_MODEL_ID",
        "COPILOT_PROVIDER_TYPE",
        "COPILOT_PROVIDER_WIRE_API",
        "COPILOT_PROVIDER_WIRE_MODEL",
        "CUSTOM_BASE_URL",
        "GEMINI_CLI_HOME",
        "GH_HOST",
        "GROK_HOME",
        "GROK_SANDBOX",
        "HERMES_CODEX_BASE_URL",
        "HERMES_HOME",
        "KIRO_HOME",
        "KIRO_LOG_LEVEL",
        "KIRO_LOG_NO_COLOR",
        "KIMI_CODE_HOME",
        "KIMI_SHARE_DIR",
        "MUSE_AUTH_PATH",
        "MUSE_CHANNEL",
        "NODE_OPTIONS",
        "OPENCODE_CONFIG",
        "OPENCODE_CONFIG_DIR",
        "OPENCODE_DB",
        "OLLAMA_EDITOR",
        "OLLAMA_HOST",
        "OLLAMA_NOHISTORY",
        "OMP_AGENT_DIR",
        "PI_CACHE_RETENTION",
        "PI_CONFIG_DIR",
        "PI_CODING_AGENT_DIR",
        "PI_CODING_AGENT_SESSION_DIR",
        "PI_OFFLINE",
        "PI_PACKAGE_DIR",
        "PI_SKIP_VERSION_CHECK",
        "QODER_CONFIG_DIR",
        "USE_BUILTIN_RIPGREP",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
    ]

    private static let sortedSafeEnvironmentKeys = safeEnvironmentKeys.sorted()

    /// Every environment key ``selectedEnvironment(from:kind:)`` reads.
    ///
    /// Out-of-process hook producers capture exactly these values so the
    /// consumer's selection matches what it would read from its own process.
    public var inputEnvironmentKeys: [String] {
        Self.sortedSafeEnvironmentKeys + [
            "CMUX_ORIGINAL_NODE_OPTIONS",
            "CMUX_ORIGINAL_NODE_OPTIONS_PRESENT",
        ]
    }

    /// Returns the subset of captured environment variables that should be replayed for an agent.
    ///
    /// The optional `kind` applies agent-specific exclusions for values that are safe for one
    /// agent but managed or incorrect for another.
    public func selectedEnvironment(from env: [String: String], kind: String? = nil) -> [String: String] {
        let normalizedKind = kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var result: [String: String] = [:]
        for key in Self.sortedSafeEnvironmentKeys where key != "NODE_OPTIONS" {
            guard let value = sanitizedValue(key: key, value: env[key]) else { continue }
            result[key] = value
        }
        if let nodeOptions = selectedNodeOptions(from: env) {
            result["NODE_OPTIONS"] = nodeOptions
        }
        if normalizedKind != "hermes-agent" {
            for key in Self.hermesAgentEnvironmentKeys {
                result.removeValue(forKey: key)
            }
        }
        if normalizedKind != "cursor" {
            result.removeValue(forKey: "CURSOR_CONFIG_DIR")
        }
        if normalizedKind != "codex" {
            result.removeValue(forKey: "CMUX_CUSTOM_CODEX_PATH")
        }
        if normalizedKind != "antigravity" {
            result.removeValue(forKey: "CMUX_CUSTOM_ANTIGRAVITY_PATH")
        }
        if !Self.isOpenCodeLaunch(normalizedKind) {
            for key in Self.openCodeLocationEnvironmentKeys {
                result.removeValue(forKey: key)
            }
        }
        if normalizedKind == "campfire" {
            for key in Self.campfireManagedEnvironmentKeys {
                result.removeValue(forKey: key)
            }
        }
        return result
    }

    /// Returns the captured environment that may cross the restore transport boundary.
    ///
    /// Pi-family agents also retain their captured `PATH` because Nix and other
    /// custom installations rely on executable locations outside the login shell.
    ///
    /// - Parameters:
    ///   - env: The captured process environment.
    ///   - kind: The restored agent kind.
    /// - Returns: The non-secret environment values safe to transport and replay.
    public func selectedRestoreEnvironment(
        from env: [String: String],
        kind: String?
    ) -> [String: String] {
        let normalizedKind = kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var selected = selectedEnvironment(from: env, kind: kind)
        if normalizedKind == "pi" || normalizedKind == "omp",
           let path = normalizedValue(env["PATH"]) {
            selected["PATH"] = path
        }
        if normalizedKind == "claude" {
            // Subrouter's resume marker and the wrapper's launch-bound copy are
            // exact command text, never a URL or credential. They cross into
            // the durable restore record only as an agreeing pair, so a marker
            // inherited from an ancestor `sr claude` session proves nothing.
            let router = SubrouterClaudeResumeRouting()
            selected.merge(router.capturedEnvironment(in: env)) { _, marker in
                marker
            }
            // The account a routed launch was pinned to, recorded by the
            // wrapper. It only picks the launcher's `--account` on restore.
            selected.merge(router.capturedAccountEnvironment(in: env)) { _, account in
                account
            }
        }
        return selected
    }

    /// Returns the bounded environment metadata that may cross the structured
    /// restore-record boundary. Subrouter's Codex resume marker is retained
    /// only when the captured argv independently proves routed execution; the
    /// ordinary restore policy still removes it before process replay.
    public func selectedRestoreRecordEnvironment(
        from env: [String: String],
        kind: String?,
        launcher: String?,
        arguments: [String]
    ) -> [String: String] {
        var selected = selectedRestoreEnvironment(from: env, kind: kind)
        let normalizedKind = kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedKind == "codex" else { return selected }

        let router = SubrouterCodexResumeRouting()
        guard router.resumeArguments(
            launcher: launcher,
            sessionID: "restore-record-validation",
            launchArguments: arguments,
            environment: env
        ) != nil,
        let marker = router.capturedMarker(in: env) else {
            return selected
        }
        selected.merge(router.capturedRoutingEnvironment(in: env)) { _, routingValue in
            routingValue
        }
        selected[SubrouterCodexResumeRouting.environmentKey] = marker
        selected[SubrouterCodexResumeRouting.launchBoundEnvironmentKey] = marker
        return selected
    }

    /// Returns replay-safe environment values for a rendered resume command.
    /// Routed Codex resumes retain their bounded account/server inputs after
    /// the metadata-only launcher marker has selected the explicit `sr` argv.
    public func selectedReplayEnvironment(
        from env: [String: String],
        kind: String?,
        launcher: String?,
        arguments: [String]
    ) -> [String: String] {
        var selected = selectedRestoreRecordEnvironment(
            from: env,
            kind: kind,
            launcher: launcher,
            arguments: arguments
        )
        selected.removeValue(forKey: SubrouterCodexResumeRouting.environmentKey)
        selected.removeValue(forKey: SubrouterCodexResumeRouting.launchBoundEnvironmentKey)
        selected.removeValue(forKey: SubrouterClaudeResumeRouting.accountEnvironmentKey)
        return selected
    }

    /// Returns a replay-safe value for a single environment variable, or `nil` when it should drop.
    public func sanitizedValue(key: String, value: String?) -> String? {
        guard Self.safeEnvironmentKeys.contains(key) else { return nil }
        switch key {
        case "CLAUDE_CONFIG_DIR":
            return value.map { ClaudeConfigDirectoryPath.preferredPath($0) }
        case "NODE_OPTIONS":
            return sanitizedNodeOptions(value)
        case _ where Self.openCodeLocationEnvironmentKeys.contains(key):
            return value.flatMap { $0.hasPrefix("/") ? $0 : nil }
        default:
            return value
        }
    }

    /// Whether `kind` (a hook kind or a launcher such as `omo`) is an OpenCode
    /// launch, by the same launcher mapping that decides capture trust.
    private static func isOpenCodeLaunch(_ normalizedKind: String?) -> Bool {
        guard let normalizedKind, !normalizedKind.isEmpty else { return false }
        return AgentLaunchCaptureTrust.launcherDescribesKind(normalizedKind, kind: "opencode")
    }

    private func normalizedValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
