import Foundation

public enum ClaudeConfigDirectoryPath {
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

public enum AgentLaunchEnvironmentPolicy {
    private static let safeEnvironmentKeys: Set<String> = [
        "ANTHROPIC_MODEL",
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
        "GEMINI_CLI_HOME",
        "GH_HOST",
        "NODE_OPTIONS",
        "OPENCODE_CONFIG_DIR",
        "QODER_CONFIG_DIR",
        "USE_BUILTIN_RIPGREP"
    ]

    public static func selectedEnvironment(from env: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in safeEnvironmentKeys.sorted() where key != "NODE_OPTIONS" {
            guard let value = sanitizedValue(key: key, value: env[key]) else { continue }
            result[key] = value
        }
        if let nodeOptions = selectedNodeOptions(from: env) {
            result["NODE_OPTIONS"] = nodeOptions
        }
        return result
    }

    public static func sanitizedValue(key: String, value: String?) -> String? {
        guard safeEnvironmentKeys.contains(key) else { return nil }
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
