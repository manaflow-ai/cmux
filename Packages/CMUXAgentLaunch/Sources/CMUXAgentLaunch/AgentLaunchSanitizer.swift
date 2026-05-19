import Foundation

public enum AgentLaunchSanitizer {
    struct Policy {
        var valueOptions: Set<String>
        var optionalValueOptions: Set<String> = []
        var variadicOptions: Set<String> = []
        var nonRestorableCommands: Set<String>
        var droppedOptions: Set<String>
        var droppedOptionPrefixes: [String] = []
        var rejectOptions: Set<String> = []
        var resumeSubcommand: String?
        var sessionSubcommands: Set<String> = []
        var preserveFirstPositional: Bool = false
        var skipClaudeHookSettings: Bool = false
    }

    public static func sanitizedLaunchArguments(
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
        case "codexTeams":
            if tail.first == "codex-teams" {
                tail.removeFirst()
            }
            guard let preserved = preservedArguments(kind: "codex", args: tail) else { return nil }
            return [executable, "codex-teams"] + preserved
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

    public static func preservedArguments(kind: String, args: [String]) -> [String]? {
        switch kind {
        case "claude":
            return preserveOptions(args, policy: claudePolicy)
        case "codex":
            return preserveOptions(args, policy: codexPolicy)
        case "grok":
            return preserveOptions(args, policy: grokPolicy)
        case "pi":
            return preserveOptions(args, policy: piPolicy)
        case "amp":
            // Strip the `threads continue <id>` resume sub-subcommand if the
            // captured launch already started by resuming a thread, so we
            // don't double-add it. Supports the documented short aliases:
            // `t`/`thread` for `threads`, and `c` for `continue`.
            var tail = args
            let threadsAliases: Set<String> = ["threads", "thread", "t"]
            let continueAliases: Set<String> = ["continue", "c"]
            if let first = tail.first, threadsAliases.contains(first) {
                tail.removeFirst()
                if let next = tail.first, continueAliases.contains(next) {
                    tail.removeFirst()
                    if let candidate = tail.first, !candidate.hasPrefix("-") {
                        tail.removeFirst()
                    }
                }
            }
            return preserveOptions(tail, policy: ampPolicy)
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
        case "hermes-agent":
            var tail = args
            if tail.first == "chat" {
                tail.removeFirst()
            } else if let command = tail.first,
                      !command.hasPrefix("-") {
                return nil
            }
            return preserveOptions(tail, policy: hermesAgentPolicy)
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

    private static func preserveOptions(_ args: [String], policy: Policy) -> [String]? {
        var result: [String] = []
        var index = 0
        var consumedFirstPositional = false
        var sessionPositionalsToSkip = 0

        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                break
            }

            if !arg.hasPrefix("-") || arg == "-" {
                if isSessionSubcommandStart(args, index: index, policy: policy) {
                    let hasSessionID = index + 1 < args.count && !args[index + 1].hasPrefix("-")
                    sessionPositionalsToSkip = hasSessionID ? 1 : 0
                    index += 1
                    continue
                }
                if sessionPositionalsToSkip > 0 {
                    sessionPositionalsToSkip -= 1
                    index += 1
                    continue
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
                if isSessionSubcommandStart(args, index: end, policy: policy) {
                    break
                }
                end += 1
            }
            return max(1, end - index)
        }
        return 2
    }

    private static func isSessionSubcommandStart(
        _ args: [String],
        index: Int,
        policy: Policy
    ) -> Bool {
        let arg = args[index]
        if let resumeSubcommand = policy.resumeSubcommand, arg == resumeSubcommand {
            return true
        }
        guard policy.sessionSubcommands.contains(arg) else {
            return false
        }
        return index + 1 < args.count && !args[index + 1].hasPrefix("-")
    }

    private static func looksLikeOptionalValue(_ value: String, following: String?) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        return following == nil || value.contains(",") || (following?.hasPrefix("-") == true)
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
