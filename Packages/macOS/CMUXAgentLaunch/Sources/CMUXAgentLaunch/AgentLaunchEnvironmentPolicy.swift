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
        "CMUX_CUSTOM_CLAUDE_PATH",
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

    /// Keys that existing launch and auto-naming policies may safely inspect
    /// after a hook crosses a process boundary. The transport still applies its
    /// own narrower routing and provider policy before persisting values.
    public static var replaySafeEnvironmentKeys: Set<String> {
        safeEnvironmentKeys
    }

    /// Returns the subset of captured environment variables that should be replayed for an agent.
    ///
    /// The optional `kind` applies agent-specific exclusions for values that are safe for one
    /// agent but managed or incorrect for another.
    public func selectedEnvironment(from env: [String: String], kind: String? = nil) -> [String: String] {
        var result: [String: String] = [:]
        for key in Self.sortedSafeEnvironmentKeys where key != "NODE_OPTIONS" {
            guard let value = sanitizedValue(key: key, value: env[key]) else { continue }
            result[key] = value
        }
        if let nodeOptions = selectedNodeOptions(from: env) {
            result["NODE_OPTIONS"] = nodeOptions
        }
        if kind != "hermes-agent" {
            for key in Self.hermesAgentEnvironmentKeys {
                result.removeValue(forKey: key)
            }
        }
        if kind == "campfire" {
            for key in Self.campfireManagedEnvironmentKeys {
                result.removeValue(forKey: key)
            }
        }
        return result
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

            if shouldDropInjectedHeapCap, isInjectedNodeHeapCap(tokens, index: index) {
                index += nodeHeapCapWidth(tokens, index: index)
                shouldDropInjectedHeapCap = false
                continue
            }
            shouldDropInjectedHeapCap = false

            if isRequireOption(token), index + 1 < tokens.count,
               isCmuxNodeOptionsRestoreModulePath(tokens[index + 1]) {
                index += 2
                shouldDropInjectedHeapCap = true
                continue
            }
            if let path = inlineRequireOptionPath(token),
               isCmuxNodeOptionsRestoreModulePath(path) {
                index += 1
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

    private func isRequireOption(_ token: String) -> Bool {
        token == "--require" || token == "-r"
    }

    private func inlineRequireOptionPath(_ token: String) -> String? {
        for prefix in ["--require=", "-r="] where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    private func isCmuxNodeOptionsRestoreModulePath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard URL(fileURLWithPath: trimmed).lastPathComponent == "restore-node-options.cjs" else {
            return false
        }
        return trimmed.contains("/cmux-")
    }

    private func isInjectedNodeHeapCap(_ tokens: [String], index: Int) -> Bool {
        guard index < tokens.count else { return false }
        let token = tokens[index]
        if token == "--max-old-space-size" {
            return index + 1 < tokens.count && tokens[index + 1] == "4096"
        }
        return token == "--max-old-space-size=4096"
    }

    private func nodeHeapCapWidth(_ tokens: [String], index: Int) -> Int {
        guard index < tokens.count else { return 1 }
        return tokens[index] == "--max-old-space-size" ? min(2, tokens.count - index) : 1
    }
}

/// Environment captured with one hook admission. Durable values are safe to
/// persist for crash recovery; credential-bearing values exist only in memory
/// for retries in the current app process.
public struct AgentHookTransportEnvironment: Sendable, Equatable {
    public let durable: [String: String]
    public let ephemeral: [String: String]

    public init(durable: [String: String], ephemeral: [String: String]) {
        self.durable = durable
        self.ephemeral = ephemeral
    }

    public var merged: [String: String] {
        durable.merging(ephemeral, uniquingKeysWith: { _, ephemeralValue in ephemeralValue })
    }
}

/// Selects the routing and auto-naming inputs that may cross the agent-hook
/// boundary. This is the shared admission policy for the native sender, the
/// portable CLI fallback, and the app-side decoder.
public struct AgentHookTransportEnvironmentPolicy: Sendable {
    public init() {}

    private static let coreKeys: Set<String> = [
        "HOME", "PATH", "PWD", "TMPDIR", "TMP", "TEMP",
        "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE",
        "CODEX_HOME",
        "CMUX_AGENT_HOOK_STATE_DIR",
        "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
        "CMUX_AGENT_LAUNCH_ARGV_B64",
        "CMUX_AGENT_LAUNCH_CWD",
        "CMUX_AGENT_LAUNCH_EXECUTABLE",
        "CMUX_AGENT_LAUNCH_KIND",
        "CMUX_AGENT_MANAGED_SUBAGENT",
        "CMUX_BUNDLE_ID",
        "CMUX_CODEX_PID",
        "CMUX_CUSTOM_CLAUDE_PATH",
        "CMUX_SOCKET_PATH",
        "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
        "CMUX_SURFACE_ID",
        "CMUX_TAG",
        "CMUX_WORKSPACE_ID",
    ]

    private static let autoNamingExactKeys: Set<String> = [
        "ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
        "all_proxy", "https_proxy", "http_proxy", "no_proxy",
        "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "SSL_CERT_DIR", "SSL_CERT_FILE",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
    ]

    private static let durableCredentialLocatorKeys: Set<String> = [
        "AWS_CONFIG_FILE",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
        "AWS_SHARED_CREDENTIALS_FILE",
        "AWS_WEB_IDENTITY_TOKEN_FILE",
        "GOOGLE_APPLICATION_CREDENTIALS",
    ]

    private static let proxyURLKeys: Set<String> = [
        "ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY",
        "all_proxy", "https_proxy", "http_proxy",
    ]

    /// Provider families intentionally accepted here are narrowed again by the
    /// selected summarizer's existing environment policy before execution.
    private static let autoNamingPrefixes = [
        "ANTHROPIC_", "AWS_", "CLOUD_ML_", "GCLOUD_", "GEMINI_", "GOOGLE_",
        "OPENAI_", "OPENROUTER_", "XAI_",
    ]

    /// Generic provider adapters use these conventional names even when cmux
    /// does not know the provider prefix ahead of time.
    private static let autoNamingSuffixes = [
        "_ACCESS_TOKEN", "_API_KEY", "_AUTH_TOKEN", "_CLIENT_SECRET",
        "_API_URL", "_BASE_URL", "_MODEL",
    ]

    private static let credentialFragments = [
        "ACCESS_KEY", "ACCESS_TOKEN", "API_KEY", "AUTH_TOKEN", "CLIENT_SECRET", "PASSWORD",
        "PRIVATE_KEY", "SECRET", "SESSION_TOKEN",
    ]

    public func partitionedEnvironment(
        from environment: [String: String]
    ) -> AgentHookTransportEnvironment {
        let launchPolicy = AgentLaunchEnvironmentPolicy()
        let replaySafeKeys = AgentLaunchEnvironmentPolicy.replaySafeEnvironmentKeys
        var durable: [String: String] = [:]
        var ephemeral: [String: String] = [:]
        durable.reserveCapacity(environment.count)
        ephemeral.reserveCapacity(8)
        for (key, value) in environment {
            let selectedValue: String
            if replaySafeKeys.contains(key) {
                guard let sanitized = launchPolicy.sanitizedValue(key: key, value: value) else {
                    continue
                }
                selectedValue = sanitized
            } else {
                guard Self.coreKeys.contains(key)
                    || Self.autoNamingExactKeys.contains(key)
                    || Self.autoNamingPrefixes.contains(where: key.hasPrefix)
                    || Self.autoNamingSuffixes.contains(where: key.hasSuffix)
                else {
                    continue
                }
                selectedValue = value
            }
            guard !selectedValue.isEmpty else { continue }
            if Self.isCredentialBearing(key: key, value: selectedValue) {
                ephemeral[key] = selectedValue
            } else {
                durable[key] = selectedValue
            }
        }
        return AgentHookTransportEnvironment(durable: durable, ephemeral: ephemeral)
    }

    public func selectedEnvironment(from environment: [String: String]) -> [String: String] {
        partitionedEnvironment(from: environment).merged
    }

    /// Removes credential-bearing values from an environment that an older
    /// cmux version may already have written to durable storage. Unlike fresh
    /// admission, this preserves unknown non-secret keys so migrations do not
    /// silently remove historical routing inputs.
    public func durableEnvironmentForPersistence(
        from environment: [String: String]
    ) -> [String: String] {
        environment.filter { key, value in
            !Self.isCredentialBearing(key: key, value: value)
        }
    }

    private static func isCredentialBearing(key: String, value: String) -> Bool {
        if durableCredentialLocatorKeys.contains(key) { return false }
        let normalized = key.uppercased()
        if credentialFragments.contains(where: normalized.contains) {
            return true
        }
        let components = normalized.split(separator: "_")
        if components.contains("KEY") || components.contains("TOKEN") {
            return true
        }
        return credentialURLContainsSecret(key: key, value: value)
    }

    private static func credentialURLContainsSecret(key: String, value: String) -> Bool {
        let normalizedKey = key.uppercased()
        guard proxyURLKeys.contains(key)
                || normalizedKey.hasSuffix("_URL")
                || normalizedKey.hasSuffix("_URI") else {
            return false
        }
        guard let components = URLComponents(string: value) else { return false }
        if components.user != nil || components.password != nil {
            return true
        }
        if components.queryItems?.contains(where: { credentialURLFieldName($0.name) }) == true {
            return true
        }
        guard let fragment = components.fragment,
              let fragmentItems = URLComponents(string: "?\(fragment)")?.queryItems else {
            return false
        }
        return fragmentItems.contains { credentialURLFieldName($0.name) }
    }

    private static func credentialURLFieldName(_ name: String) -> Bool {
        let normalized = name.uppercased()
        if credentialFragments.contains(where: normalized.contains) {
            return true
        }
        let components = normalized.split { character in
            !character.isLetter && !character.isNumber
        }
        return components.contains("AUTH")
            || components.contains("AUTHORIZATION")
            || components.contains("CREDENTIAL")
            || components.contains("KEY")
            || components.contains("PASSWORD")
            || components.contains("SECRET")
            || components.contains("SIGNATURE")
            || components.contains("TOKEN")
    }
}
