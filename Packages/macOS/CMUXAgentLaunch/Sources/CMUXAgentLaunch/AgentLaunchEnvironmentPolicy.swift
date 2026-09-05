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
}

/// The preload module cmux injects via `NODE_OPTIONS=--require=…` so that child node processes
/// get the caller's original `NODE_OPTIONS` back instead of cmux's own heap cap.
///
/// The claude wrapper, the CLI, and this policy each handle the module from a different side —
/// two write it, one strips it back out — so the rule for "is this path ours" lives here once.
public struct ClaudeNodeOptionsRestoreModule: Sendable {
    private init() {}

    /// The module's file name, identical in every directory cmux has written it to.
    public static let fileName = "restore-node-options.cjs"

    /// The directory holding the module under the cmux state directory.
    public static let directoryName = "node-options"

    /// The `$TMPDIR` directory older builds used. The remote daemon still appends a random suffix
    /// to it, so both the exact name and the `<name>-<random>` form count as cmux's.
    private static let legacyDirectoryName = "cmux-claude-node-options"

    /// The V8 heap cap, in MB, that cmux injects alongside the module. Named because unwinding an
    /// injected `NODE_OPTIONS` has to tell cmux's own value apart from one the caller chose.
    public static let injectedHeapCapMB = "4096"

    /// Name of the cmux state directory. Duplicated from `CmuxStateDirectory` because this target
    /// has no dependencies; it is the leaf of `~/.local/state/cmux`.
    private static let stateDirectoryName = "cmux"

    /// The full directory tail cmux writes the module to, below the user's home. Matching the
    /// whole tail rather than just `cmux/node-options` keeps an unrelated preload at, say,
    /// `/opt/vendor/cmux/node-options/` from being claimed as ours.
    private static let stateDirectoryTail = [".local", "state", stateDirectoryName, directoryName]

    /// Whether a `--require` path points at a cmux-written copy of the module.
    ///
    /// The file name alone is not enough: a caller may legitimately preload their own module of
    /// the same name, and dropping that would silently change their runtime. Path shape alone is
    /// not enough either — it is both too generous (an unrelated `…/cmux/node-options/`) and too
    /// mean (a configured directory that looks like neither known shape). So the authoritative
    /// test is `moduleDirectory`, the directory the caller actually writes to; the name and tail
    /// checks only recognise copies left by another process or an older build.
    ///
    /// - Parameter moduleDirectory: Where this process writes the module, when it writes one.
    ///   Callers that only strip inherited values (they never write) pass `nil`.
    public static func isCmuxOwnedPath(_ path: String, moduleDirectory: URL? = nil) -> Bool {
        let unquoted = path.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        let moduleURL = URL(fileURLWithPath: unquoted).standardizedFileURL
        guard moduleURL.lastPathComponent == fileName else { return false }

        let parent = moduleURL.deletingLastPathComponent()
        if let moduleDirectory, parent == moduleDirectory.standardizedFileURL {
            return true
        }

        let parentName = parent.lastPathComponent
        if parentName == legacyDirectoryName || parentName.hasPrefix("\(legacyDirectoryName)-") {
            return true
        }
        return parent.pathComponents.suffix(stateDirectoryTail.count).elementsEqual(stateDirectoryTail)
    }

    /// How many tokens a cmux-owned `--require` occupies at `index`, or `0` when the token there
    /// is not one.
    ///
    /// Both `--require=<path>` and `--require <path>` (and the `-r` spellings) have to be
    /// recognised: a persisted launch environment can carry either shape, and missing the
    /// space-separated one leaves a dead preload in `NODE_OPTIONS` — the failure this whole
    /// mechanism exists to avoid.
    public static func ownedRequireTokenWidth(
        _ tokens: [String],
        index: Int,
        moduleDirectory: URL? = nil
    ) -> Int {
        guard index < tokens.count else { return 0 }
        let token = tokens[index]

        for prefix in ["--require=", "-r="] where token.hasPrefix(prefix) {
            let path = String(token.dropFirst(prefix.count))
            return isCmuxOwnedPath(path, moduleDirectory: moduleDirectory) ? 1 : 0
        }
        guard token == "--require" || token == "-r", index + 1 < tokens.count else { return 0 }
        return isCmuxOwnedPath(tokens[index + 1], moduleDirectory: moduleDirectory) ? 2 : 0
    }

    /// Whether the token at `index` is the heap cap cmux injects, rather than one the caller chose.
    public static func isInjectedHeapCap(_ tokens: [String], index: Int) -> Bool {
        guard index < tokens.count else { return false }
        let token = tokens[index]
        if token == "--max-old-space-size" {
            return index + 1 < tokens.count && tokens[index + 1] == injectedHeapCapMB
        }
        return token == "--max-old-space-size=\(injectedHeapCapMB)"
    }

    /// How many tokens the heap cap at `index` occupies: two for the space-separated form, one for
    /// the `=` form.
    public static func heapCapTokenWidth(_ tokens: [String], index: Int) -> Int {
        guard index < tokens.count else { return 1 }
        return tokens[index] == "--max-old-space-size" ? min(2, tokens.count - index) : 1
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
        // Selects the directory holding Claude Code's .credentials.json. A path, not a secret,
        // so restoring it keeps a restored agent on the account it launched with.
        "CLAUDE_SECURESTORAGE_CONFIG_DIR",
        "CMUX_CUSTOM_CLAUDE_PATH",
        "CMUX_CUSTOM_AMP_PATH",
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
        "NODE_OPTIONS",
        "OPENCODE_CONFIG_DIR",
        "OLLAMA_EDITOR",
        "OLLAMA_HOST",
        "OLLAMA_NOHISTORY",
        "PI_CACHE_RETENTION",
        "PI_CONFIG_DIR",
        "PI_CODING_AGENT_DIR",
        "PI_CODING_AGENT_SESSION_DIR",
        "PI_OFFLINE",
        "PI_PACKAGE_DIR",
        "PI_SKIP_VERSION_CHECK",
        "QODER_CONFIG_DIR",
        "USE_BUILTIN_RIPGREP"
    ]

    private static let sortedSafeEnvironmentKeys = safeEnvironmentKeys.sorted()

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
        default:
            return value
        }
    }

    private func selectedNodeOptions(from env: [String: String]) -> String? {
        switch normalizedValue(env["CMUX_ORIGINAL_NODE_OPTIONS_PRESENT"]) {
        case "1":
            return sanitizedNodeOptions(env["CMUX_ORIGINAL_NODE_OPTIONS"])
        case "0":
            return nil
        default:
            return sanitizedNodeOptions(env["NODE_OPTIONS"])
        }
    }

    private func sanitizedNodeOptions(_ rawValue: String?) -> String? {
        let tokens = rawValue?
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) ?? []
        guard !tokens.isEmpty else { return nil }

        var sanitized: [String] = []
        var index = 0
        var shouldDropInjectedHeapCap = false
        while index < tokens.count {
            let token = tokens[index]

            if shouldDropInjectedHeapCap, ClaudeNodeOptionsRestoreModule.isInjectedHeapCap(tokens, index: index) {
                index += ClaudeNodeOptionsRestoreModule.heapCapTokenWidth(tokens, index: index)
                shouldDropInjectedHeapCap = false
                continue
            }
            shouldDropInjectedHeapCap = false

            let ownedRequireWidth = ClaudeNodeOptionsRestoreModule.ownedRequireTokenWidth(tokens, index: index)
            if ownedRequireWidth > 0 {
                index += ownedRequireWidth
                shouldDropInjectedHeapCap = true
                continue
            }

            sanitized.append(token)
            index += 1
        }

        let joined = sanitized.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func normalizedValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

}
