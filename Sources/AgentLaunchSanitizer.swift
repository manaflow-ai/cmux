import Foundation

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
            "--prompt",
            "-p",
            "--prompt-interactive",
            "-i",
            "--delete-session",
            "--output-format",
            "-o"
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

    private static let rovoDevPolicy = Policy(
        valueOptions: [
            "--config",
            "--config-file",
            "--model",
            "--model-id",
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
