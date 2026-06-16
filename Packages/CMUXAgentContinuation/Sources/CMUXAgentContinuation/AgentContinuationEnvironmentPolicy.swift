import Foundation

/// Selects the non-secret environment values required to continue an agent session.
public enum AgentContinuationEnvironmentPolicy {
    private static let commonKeys: Set<String> = [
        "GH_HOST",
        "USE_BUILTIN_RIPGREP",
    ]

    private static let keysByKind: [String: Set<String>] = [
        "amp": [
            "AMP_LOG_FILE",
            "AMP_LOG_LEVEL",
            "AMP_SETTINGS_FILE",
            "AMP_URL",
        ],
        "antigravity": [
            "GEMINI_CLI_HOME",
        ],
        "claude": [
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_MODEL",
            "CLAUDE_CONFIG_DIR",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            "CMUX_CUSTOM_CLAUDE_PATH",
        ],
        "codex": [
            "CODEX_HOME",
        ],
        "codebuddy": [
            "CODEBUDDY_BASE_URL",
            "CODEBUDDY_CONFIG_DIR",
            "CODEBUDDY_ENV_FILE",
            "CODEBUDDY_INTERNET_ENVIRONMENT",
            "CODEBUDDY_MODEL",
            "CODEBUDDY_SMALL_FAST_MODEL",
        ],
        "copilot": [
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
        ],
        "cursor": [
            "CURSOR_AGENT_HOME",
            "CURSOR_CONFIG_DIR",
            "CURSOR_HOME",
        ],
        "factory": [],
        "gemini": [
            "GEMINI_CLI_HOME",
        ],
        "grok": [
            "GROK_HOME",
            "GROK_SANDBOX",
        ],
        "hermes-agent": [
            "CODEX_HOME",
            "CUSTOM_BASE_URL",
            "HERMES_CODEX_BASE_URL",
            "HERMES_HOME",
        ],
        "kiro": [
            "KIRO_HOME",
            "KIRO_LOG_LEVEL",
            "KIRO_LOG_NO_COLOR",
        ],
        "omp": [
            "PI_CACHE_RETENTION",
            "PI_CODING_AGENT_DIR",
            "PI_CODING_AGENT_SESSION_DIR",
            "PI_CONFIG_DIR",
            "PI_OFFLINE",
            "PI_PACKAGE_DIR",
            "PI_SKIP_VERSION_CHECK",
        ],
        "opencode": [
            "OPENCODE_CONFIG_DIR",
        ],
        "pi": [
            "PI_CACHE_RETENTION",
            "PI_CODING_AGENT_DIR",
            "PI_CODING_AGENT_SESSION_DIR",
            "PI_CONFIG_DIR",
            "PI_OFFLINE",
            "PI_PACKAGE_DIR",
            "PI_SKIP_VERSION_CHECK",
        ],
        "qoder": [
            "QODER_CONFIG_DIR",
        ],
        "rovodev": [
            "CMUX_ROVODEV_SESSIONS_DIR",
        ],
    ]

    private static let nodeOptionsKinds: Set<String> = [
        "claude",
    ]

    /// Returns the continuation-safe environment for `kind`.
    public static func selectedEnvironment(from env: [String: String], kind: String? = nil) -> [String: String] {
        let normalizedKind = canonicalKind(kind)
        let allowedKeys = commonKeys.union(normalizedKind.flatMap { keysByKind[$0] } ?? [])
        var result: [String: String] = [:]
        for key in allowedKeys.sorted() {
            guard let value = sanitizedValue(key: key, value: env[key]) else { continue }
            result[key] = value
        }
        if let normalizedKind,
           nodeOptionsKinds.contains(normalizedKind),
           let nodeOptions = selectedNodeOptions(from: env) {
            result["NODE_OPTIONS"] = nodeOptions
        }
        return result
    }

    private static func canonicalKind(_ kind: String?) -> String? {
        guard let normalized = kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty
        else {
            return nil
        }
        switch normalized {
        case "claudeteams", "claude-teams":
            return "claude"
        case "codexteams", "codex-teams":
            return "codex"
        case "omo", "omx", "omc":
            return "opencode"
        case "rovo", "rovo-dev", "rovodev":
            return "rovodev"
        default:
            return normalized
        }
    }

    /// Returns a sanitized value for a continuation-safe key, or `nil` when the key is not safe.
    public static func sanitizedValue(key: String, value: String?) -> String? {
        guard commonKeys.contains(key) || keysByKind.values.contains(where: { $0.contains(key) }) || key == "NODE_OPTIONS" else {
            return nil
        }
        switch key {
        case "CLAUDE_CONFIG_DIR":
            return value.map { ClaudeConfigDirectoryPath.preferredPath($0) }
        case "NODE_OPTIONS":
            return sanitizedNodeOptions(value)
        default:
            return value
        }
    }

    private static func selectedNodeOptions(from env: [String: String]) -> String? {
        switch normalizedValue(env["CMUX_ORIGINAL_NODE_OPTIONS_PRESENT"]) {
        case "1":
            return sanitizedNodeOptions(env["CMUX_ORIGINAL_NODE_OPTIONS"])
        case "0":
            return nil
        default:
            return sanitizedNodeOptions(env["NODE_OPTIONS"])
        }
    }

    private static func sanitizedNodeOptions(_ rawValue: String?) -> String? {
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

    private static func normalizedValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func isRequireOption(_ token: String) -> Bool {
        token == "--require" || token == "-r"
    }

    private static func inlineRequireOptionPath(_ token: String) -> String? {
        for prefix in ["--require=", "-r="] where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    private static func isCmuxNodeOptionsRestoreModulePath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard URL(fileURLWithPath: trimmed).lastPathComponent == "restore-node-options.cjs" else {
            return false
        }
        return trimmed.contains("/cmux-")
    }

    private static func isInjectedNodeHeapCap(_ tokens: [String], index: Int) -> Bool {
        guard index < tokens.count else { return false }
        let token = tokens[index]
        if token == "--max-old-space-size" {
            return index + 1 < tokens.count && tokens[index + 1] == "4096"
        }
        return token == "--max-old-space-size=4096"
    }

    private static func nodeHeapCapWidth(_ tokens: [String], index: Int) -> Int {
        guard index < tokens.count else { return 1 }
        return tokens[index] == "--max-old-space-size" ? min(2, tokens.count - index) : 1
    }
}
