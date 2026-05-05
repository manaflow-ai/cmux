import Foundation

enum ClaudeConfigDirectoryPath {
    static func preferredPath(
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

enum AgentLaunchEnvironmentPolicy {
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

    static func selectedEnvironment(from env: [String: String]) -> [String: String] {
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

    static func sanitizedValue(key: String, value: String?) -> String? {
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

enum AgentLaunchSanitizer {
    struct Policy {
        var valueOptions: Set<String>
        var optionalValueOptions: Set<String> = []
        var variadicOptions: Set<String> = []
        var nonRestorableCommands: Set<String>
        var droppedOptions: Set<String>
        var droppedOptionPrefixes: [String] = []
        var rejectOptions: Set<String> = []
        var resumeSubcommand: String?
        var preserveFirstPositional: Bool = false
        var skipClaudeHookSettings: Bool = false
    }

    static func sanitizedLaunchArguments(
        _ arguments: [String],
        launcher: String,
        fallbackKind: String
    ) -> [String]? {
        guard let executable = arguments.first, !executable.isEmpty else { return nil }
        var tail = Array(arguments.dropFirst())

        switch launcher {
        case "claudeTeams":
            if tail.first == "claude-teams" {
                tail.removeFirst()
            }
            guard let preserved = preservedArguments(kind: "claude", args: tail) else { return nil }
            return [executable, "claude-teams"] + preserved
        case "omo":
            if tail.first == "omo" {
                tail.removeFirst()
            }
            guard let preserved = preservedArguments(kind: "opencode", args: tail) else { return nil }
            return [executable, "omo"] + preserved
        case "omx", "omc":
            return nil
        default:
            break
        }

        switch fallbackKind {
        case "rovodev":
            guard let preserved = preservedArguments(kind: fallbackKind, args: tail) else { return nil }
            return [executable, "rovodev", "run"] + preserved
        default:
            guard let preserved = preservedArguments(kind: fallbackKind, args: tail) else { return nil }
            return [executable] + preserved
        }
    }

    static func preservedArguments(kind: String, args: [String]) -> [String]? {
        switch kind {
        case "claude":
            return preserveOptions(args, policy: claudePolicy)
        case "codex":
            return preserveOptions(args, policy: codexPolicy)
        case "cursor":
            var tail = args
            if tail.first == "agent" {
                tail.removeFirst()
            }
            return preserveOptions(tail, policy: cursorPolicy)
        case "gemini":
            return preserveOptions(args, policy: geminiPolicy)
        case "opencode":
            return preserveOptions(
                args.filter { !isOpenCodeInternalWorkerArgument($0) },
                policy: openCodePolicy
            )
        case "rovodev":
            var tail = args
            if tail.first == "rovodev" {
                tail.removeFirst()
            }
            if tail.first == "run" {
                tail.removeFirst()
            } else if let command = tail.first, !command.hasPrefix("-") {
                return nil
            }
            return preserveOptions(tail, policy: rovoDevPolicy)
        case "copilot":
            return preserveOptions(args, policy: copilotPolicy)
        case "codebuddy":
            return preserveOptions(args, policy: codeBuddyPolicy)
        case "factory":
            return preserveOptions(args, policy: factoryPolicy)
        case "qoder":
            return preserveOptions(args, policy: qoderPolicy)
        default:
            return nil
        }
    }

    private static let claudePolicy = Policy(
        valueOptions: [
            "--add-dir",
            "--agent",
            "--agents",
            "--allowedTools",
            "--allowed-tools",
            "--append-system-prompt",
            "--betas",
            "--debug-file",
            "--disallowedTools",
            "--disallowed-tools",
            "--effort",
            "--fallback-model",
            "--file",
            "--fork-session",
            "--from-pr",
            "--input-format",
            "--json-schema",
            "--max-budget-usd",
            "--mcp-config",
            "--model",
            "--name",
            "-n",
            "--output-format",
            "--permission-mode",
            "--plugin-dir",
            "--remote-control-session-name-prefix",
            "--resume",
            "-r",
            "--session-id",
            "--setting-sources",
            "--settings",
            "--system-prompt",
            "--teammate-mode",
            "--tmux",
            "--tools",
            "--worktree",
            "-w"
        ],
        optionalValueOptions: [
            "--debug"
        ],
        variadicOptions: [
            "--add-dir",
            "--allowedTools",
            "--allowed-tools",
            "--betas",
            "--disallowedTools",
            "--disallowed-tools",
            "--file",
            "--mcp-config",
            "--tools"
        ],
        nonRestorableCommands: [
            "agents",
            "auth",
            "auto-mode",
            "api-key",
            "config",
            "doctor",
            "install",
            "mcp",
            "plugin",
            "plugins",
            "rc",
            "remote-control",
            "setup-token",
            "update",
            "upgrade"
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "--fork-session",
            "--from-pr",
            "--resume",
            "-r",
            "--session-id",
            "--tmux",
            "--worktree",
            "-w"
        ],
        droppedOptionPrefixes: [
            "--fork-session=",
            "--from-pr=",
            "--resume=",
            "--session-id=",
            "--tmux=",
            "--worktree="
        ],
        rejectOptions: [
            "--print",
            "-p",
            "--no-session-persistence"
        ],
        skipClaudeHookSettings: true
    )

    private static let codexPolicy = Policy(
        valueOptions: [
            "--config",
            "-c",
            "--remote",
            "--remote-auth-token-env",
            "--image",
            "-i",
            "--model",
            "-m",
            "--local-provider",
            "--profile",
            "-p",
            "--sandbox",
            "-s",
            "--ask-for-approval",
            "-a",
            "--cd",
            "-C",
            "--add-dir",
            "--enable",
            "--disable"
        ],
        variadicOptions: [
            "--image",
            "-i",
            "--add-dir"
        ],
        nonRestorableCommands: [
            "exec",
            "e",
            "review",
            "login",
            "logout",
            "mcp",
            "mcp-server",
            "app-server",
            "app",
            "completion",
            "sandbox",
            "debug",
            "apply",
            "a",
            "fork",
            "cloud",
            "exec-server",
            "features",
            "help"
        ],
        droppedOptions: [
            "--last",
            "--all"
        ],
        resumeSubcommand: "resume"
    )

    private static let geminiPolicy = Policy(
        valueOptions: [
            "--model",
            "-m",
            "--sandbox",
            "-s",
            "--approval-mode",
            "--policy",
            "--admin-policy",
            "--allowed-mcp-server-names",
            "--allowed-tools",
            "--extensions",
            "-e",
            "--include-directories",
            "--resume",
            "-r",
            "--session-id",
            "--worktree",
            "-w",
            "--prompt",
            "-p",
            "--prompt-interactive",
            "-i",
            "--delete-session",
            "--output-format",
            "-o"
        ],
        optionalValueOptions: [
            "--resume",
            "-r"
        ],
        variadicOptions: [
            "--policy",
            "--admin-policy",
            "--allowed-mcp-server-names",
            "--allowed-tools",
            "--extensions",
            "-e",
            "--include-directories"
        ],
        nonRestorableCommands: [
            "mcp",
            "extensions",
            "skills",
            "hooks",
            "gemma",
            "help"
        ],
        droppedOptions: [
            "--resume",
            "-r",
            "--session-id",
            "--worktree",
            "-w"
        ],
        droppedOptionPrefixes: [
            "--resume=",
            "--session-id=",
            "--worktree="
        ],
        rejectOptions: [
            "--prompt",
            "-p",
            "--prompt-interactive",
            "-i",
            "--list-sessions",
            "--delete-session",
            "--output-format",
            "-o",
            "--raw-output",
            "--accept-raw-output-risk",
            "--acp",
            "--experimental-acp",
            "--list-extensions"
        ]
    )

    private static let cursorPolicy = Policy(
        valueOptions: [
            "--api-key",
            "-H",
            "--header",
            "--mode",
            "--model",
            "--output-format",
            "--resume",
            "--sandbox",
            "--workspace",
            "-w",
            "--worktree",
            "--worktree-base"
        ],
        optionalValueOptions: [
            "-w",
            "--resume",
            "--worktree"
        ],
        nonRestorableCommands: [
            "about",
            "create-chat",
            "generate-rule",
            "help",
            "install-shell-integration",
            "login",
            "logout",
            "ls",
            "mcp",
            "models",
            "resume",
            "rule",
            "status",
            "uninstall-shell-integration",
            "update",
            "whoami"
        ],
        droppedOptions: [
            "--api-key",
            "-H",
            "--header",
            "--continue",
            "--resume",
            "--workspace",
            "-w",
            "--worktree",
            "--worktree-base",
            "--skip-worktree-setup"
        ],
        droppedOptionPrefixes: [
            "--api-key=",
            "--header=",
            "-H=",
            "--resume=",
            "--workspace=",
            "--worktree=",
            "--worktree-base="
        ],
        rejectOptions: [
            "--cloud",
            "--output-format",
            "--print",
            "-p",
            "--stream-partial-output"
        ]
    )

    private static let openCodePolicy = Policy(
        valueOptions: [
            "--log-level",
            "--port",
            "--hostname",
            "--mdns-domain",
            "--cors",
            "--model",
            "-m",
            "--session",
            "-s",
            "--prompt",
            "--agent"
        ],
        variadicOptions: [
            "--cors"
        ],
        nonRestorableCommands: [
            "completion",
            "acp",
            "mcp",
            "attach",
            "run",
            "debug",
            "providers",
            "auth",
            "agent",
            "upgrade",
            "uninstall",
            "serve",
            "web",
            "models",
            "stats",
            "export",
            "import",
            "pr",
            "github",
            "session",
            "plugin",
            "plug",
            "db"
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "--fork",
            "--session",
            "-s",
            "--prompt"
        ],
        droppedOptionPrefixes: [
            "--session=",
            "--prompt="
        ],
        preserveFirstPositional: true
    )

    private static let copilotPolicy = Policy(
        valueOptions: [
            "--add-dir",
            "--add-github-mcp-tool",
            "--add-github-mcp-toolset",
            "--additional-mcp-config",
            "--agent",
            "--allow-tool",
            "--allow-url",
            "--available-tools",
            "--bash-env",
            "--connect",
            "--deny-tool",
            "--deny-url",
            "--disable-mcp-server",
            "--effort",
            "--excluded-tools",
            "--interactive",
            "-i",
            "--log-dir",
            "--log-level",
            "--max-autopilot-continues",
            "--mode",
            "--model",
            "-n",
            "--name",
            "--output-format",
            "--plugin-dir",
            "--prompt",
            "-p",
            "--reasoning-effort",
            "--resume",
            "--secret-env-vars",
            "--share",
            "--stream"
        ],
        optionalValueOptions: [
            "--allow-tool",
            "--allow-url",
            "--available-tools",
            "--bash-env",
            "--connect",
            "--deny-tool",
            "--deny-url",
            "--excluded-tools",
            "--mouse",
            "--resume",
            "--secret-env-vars",
            "--share"
        ],
        variadicOptions: [
            "--add-dir",
            "--add-github-mcp-tool",
            "--add-github-mcp-toolset",
            "--additional-mcp-config",
            "--allow-tool",
            "--allow-url",
            "--available-tools",
            "--deny-tool",
            "--deny-url",
            "--disable-mcp-server",
            "--excluded-tools",
            "--plugin-dir",
            "--secret-env-vars"
        ],
        nonRestorableCommands: [
            "completion",
            "help",
            "init",
            "login",
            "mcp",
            "plugin",
            "update",
            "version"
        ],
        droppedOptions: [
            "--connect",
            "--continue",
            "--interactive",
            "-i",
            "--resume"
        ],
        droppedOptionPrefixes: [
            "--connect=",
            "--interactive=",
            "-i=",
            "--resume="
        ],
        rejectOptions: [
            "--acp",
            "--output-format",
            "--prompt",
            "-p",
            "--share",
            "--share-gist",
            "--silent",
            "-s"
        ]
    )

    private static let codeBuddyPolicy = Policy(
        valueOptions: [
            "--add-dir",
            "--agent",
            "--agents",
            "--allowedTools",
            "--append-system-prompt",
            "--channels",
            "--dangerously-load-development-channels",
            "--disallowedTools",
            "--fallback-model",
            "-H",
            "--header",
            "--image-to-image-model",
            "--input-format",
            "--json-schema",
            "--max-turns",
            "--mcp-config",
            "--model",
            "--name",
            "--output-format",
            "--permission-mode",
            "--plugin-dir",
            "--port",
            "--resume",
            "-r",
            "--sandbox",
            "--sandbox-id",
            "--setting-sources",
            "--settings",
            "--session-id",
            "--subagent-permission-mode",
            "--system-prompt",
            "--system-prompt-file",
            "--teleport",
            "--text-to-image-model",
            "--tools",
            "--worktree",
            "-w",
            "--worktree-branch"
        ],
        optionalValueOptions: [
            "--debug",
            "--resume",
            "-r",
            "--sandbox",
            "--worktree",
            "-w"
        ],
        variadicOptions: [
            "--add-dir",
            "--allowedTools",
            "--disallowedTools",
            "--mcp-config",
            "--plugin-dir"
        ],
        nonRestorableCommands: [
            "attach",
            "config",
            "daemon",
            "doctor",
            "help",
            "install",
            "kill",
            "logs",
            "mcp",
            "plugin",
            "ps",
            "sandbox",
            "update"
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "-H",
            "--header",
            "--fork-session",
            "--name",
            "--resume",
            "-r",
            "--session-id",
            "--tmux",
            "--tmux-classic",
            "--worktree",
            "-w",
            "--worktree-branch"
        ],
        droppedOptionPrefixes: [
            "--header=",
            "-H=",
            "--name=",
            "--resume=",
            "-r=",
            "--session-id=",
            "--worktree=",
            "-w=",
            "--worktree-branch="
        ],
        rejectOptions: [
            "--acp",
            "--background",
            "--bg",
            "--input-format",
            "--output-format",
            "--print",
            "-p",
            "--serve"
        ]
    )

    private static let factoryPolicy = Policy(
        valueOptions: [
            "--append-system-prompt",
            "--append-system-prompt-file",
            "--cwd",
            "--fork",
            "--resume",
            "-r",
            "--settings",
            "--worktree",
            "-w",
            "--worktree-dir"
        ],
        optionalValueOptions: [
            "--resume",
            "-r",
            "--worktree",
            "-w"
        ],
        nonRestorableCommands: [
            "computer",
            "daemon",
            "exec",
            "find",
            "help",
            "mcp",
            "plugin",
            "search",
            "update"
        ],
        droppedOptions: [
            "--fork",
            "--resume",
            "-r",
            "--worktree",
            "-w",
            "--worktree-dir"
        ],
        droppedOptionPrefixes: [
            "--fork=",
            "--resume=",
            "-r=",
            "--worktree=",
            "-w=",
            "--worktree-dir="
        ]
    )

    private static let qoderPolicy = Policy(
        valueOptions: [
            "--agent",
            "--agents",
            "--allowed-mcp-server-names",
            "--allowed-tools",
            "--append-system-prompt",
            "--attachment",
            "--cwd",
            "--delete-session",
            "--disallowed-tools",
            "--input-format",
            "--max-output-tokens",
            "--mcp-config",
            "--model",
            "-m",
            "--name",
            "-n",
            "--output-format",
            "-o",
            "-f",
            "--permission-mode",
            "--plugin-dir",
            "--prompt-interactive",
            "-i",
            "--resume",
            "-r",
            "--session-id",
            "--setting-sources",
            "--settings",
            "--system-prompt",
            "--tools",
            "--workspace",
            "-w"
        ],
        variadicOptions: [
            "--allowed-mcp-server-names",
            "--allowed-tools",
            "--attachment",
            "--disallowed-tools",
            "--mcp-config",
            "--plugin-dir",
            "--setting-sources",
            "--tools"
        ],
        nonRestorableCommands: [
            "agent",
            "agents",
            "feedback",
            "help",
            "hook",
            "hooks",
            "login",
            "mcp",
            "plugin",
            "plugins",
            "skill",
            "skills",
            "update"
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "--fork-session",
            "--resume",
            "-r",
            "--session-id"
        ],
        droppedOptionPrefixes: [
            "--resume=",
            "-r=",
            "--session-id="
        ],
        rejectOptions: [
            "--acp",
            "--delete-session",
            "--input-format",
            "--list-sessions",
            "--output-format",
            "-o",
            "-f",
            "--print",
            "-p",
            "--prompt-interactive",
            "-i"
        ]
    )

    private static let rovoDevPolicy = Policy(
        valueOptions: [
            "--config",
            "--config-file",
            "--model",
            "--model-id",
            "--restore"
        ],
        optionalValueOptions: [
            "--restore"
        ],
        nonRestorableCommands: [
            "auth",
            "config",
            "help",
            "mcp",
            "server",
            "update",
            "upgrade",
            "version"
        ],
        droppedOptions: [
            "--restore"
        ],
        droppedOptionPrefixes: [
            "--restore="
        ]
    )

    private static func preserveOptions(_ args: [String], policy: Policy) -> [String]? {
        var result: [String] = []
        var index = 0
        var consumedFirstPositional = false
        var skippingResumePositionals = false

        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                break
            }

            if !arg.hasPrefix("-") || arg == "-" {
                if let resumeSubcommand = policy.resumeSubcommand, arg == resumeSubcommand {
                    skippingResumePositionals = true
                    index += 1
                    continue
                }
                if skippingResumePositionals {
                    break
                }
                if policy.nonRestorableCommands.contains(arg) {
                    return nil
                }
                if policy.preserveFirstPositional, !consumedFirstPositional {
                    result.append(arg)
                    consumedFirstPositional = true
                    index += 1
                    continue
                }
                break
            }

            if shouldDropOption(arg, droppedOptions: policy.rejectOptions) {
                return nil
            }

            if policy.droppedOptionPrefixes.contains(where: { arg.hasPrefix($0) }) {
                index += 1
                continue
            }

            let width = optionWidth(args, index: index, policy: policy)
            if shouldDropOption(arg, droppedOptions: policy.droppedOptions) {
                index += width
                continue
            }

            if policy.skipClaudeHookSettings, isClaudeHookSettingsOption(args, index: index) {
                index += width
                continue
            }

            result.append(contentsOf: args[index..<min(args.count, index + width)])
            index += width
        }

        return result
    }

    private static func shouldDropOption(_ arg: String, droppedOptions: Set<String>) -> Bool {
        if droppedOptions.contains(arg) { return true }
        guard let equals = arg.firstIndex(of: "=") else { return false }
        return droppedOptions.contains(String(arg[..<equals]))
    }

    private static func optionWidth(_ args: [String], index: Int, policy: Policy) -> Int {
        let arg = args[index]
        if arg.contains("=") {
            return 1
        }
        if policy.optionalValueOptions.contains(arg) {
            guard index + 1 < args.count,
                  looksLikeOptionalValue(
                    args[index + 1],
                    following: index + 2 < args.count ? args[index + 2] : nil
                  ) else {
                return 1
            }
            return 2
        }
        guard policy.valueOptions.contains(arg), index + 1 < args.count else {
            return 1
        }
        if policy.variadicOptions.contains(arg) {
            var end = index + 1
            while end < args.count, !args[end].hasPrefix("-") {
                end += 1
            }
            return max(1, end - index)
        }
        return 2
    }

    private static func looksLikeOptionalValue(_ value: String, following: String?) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        return value.contains(",") || (following?.hasPrefix("-") == true)
    }

    private static func isClaudeHookSettingsOption(_ args: [String], index: Int) -> Bool {
        let arg = args[index]
        if arg.hasPrefix("--settings=") {
            return arg.contains("claude-hook") || arg.contains("hooks claude")
        }
        guard arg == "--settings", index + 1 < args.count else {
            return false
        }
        return args[index + 1].contains("claude-hook") || args[index + 1].contains("hooks claude")
    }

    private static func isOpenCodeInternalWorkerArgument(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        return normalized.contains("/$bunfs/") &&
            normalized.contains("/src/cli/cmd/tui/worker.js")
    }
}
