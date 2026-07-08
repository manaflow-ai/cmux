import Foundation

public enum AgentLaunchSanitizer {
    // Runtime/interpreter flags may appear in captured process argv, but they
    // are not portable agent session options to replay after a resume command.
    // Values are token widths, including the option token itself.
    private static let runtimeOnlyOptionWidths: [String: Int] = [
        "--use-system-ca": 1,
    ]
    private static let claudeCmuxSettingsKeys: Set<String> = [
        "hooks",
        "preferredNotifChannel",
    ]
    private enum ClaudeHookSettingsReplacement {
        case drop
        case settings(String)
    }

    struct Policy {
        var valueOptions: Set<String>
        var optionalValueOptions: Set<String> = []; var optionalValueChoices: [String: Set<String>] = [:]; var greedyOptionalValueOptions: Set<String> = []
        var variadicOptions: Set<String> = []
        var nonRestorableCommands: Set<String>
        var droppedOptions: Set<String>
        var droppedOptionPrefixes: [String] = []
        var rejectOptions: Set<String> = []
        var promptBoundaryOptions: Set<String> = []
        var resumeSubcommand: String?
        var preserveFirstPositional: Bool = false
        var preservePositionals: Bool = false
        /// Keeps scanning for top-level option tokens after prompt positionals; only Claude supports this replay boundary.
        var scansOptionsPastPositionals: Bool = false
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
            guard let preserved = preservedClaudeTeamsLaunchArguments(args: tail) else { return nil }
            return [executable, "claude-teams"] + preserved
        case "codexTeams":
            if tail.first == "codex-teams" {
                tail.removeFirst()
            }
            guard let preserved = preservedCodexLaunchArguments(args: tail) else { return nil }
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
        case "codex":
            guard let preserved = preservedCodexLaunchArguments(args: tail) else { return nil }
            return [executable] + preserved
        case "rovodev":
            guard let preserved = preservedArguments(kind: fallbackKind, args: tail) else { return nil }
            return [executable, "rovodev", "run"] + preserved
        default:
            guard let preserved = preservedArguments(kind: fallbackKind, args: tail) else { return nil }
            return [executable] + preserved
        }
    }

    public static func preservedArguments(kind: String, args: [String]) -> [String]? {
        func preserveCodexFork(_ preservePromptTags: Bool) -> [String]? {
            func dropForkPositionals(_ args: [String], forkCommand: CodexForkCommand) -> [String] {
                var result: [String] = []
                var index = 0
                var skippedSession = false

                while index < args.count {
                    let arg = args[index]
                    if arg == "--" { break }
                    if index == forkCommand.forkIndex { index += 1; continue }
                    if index == forkCommand.sessionIndex { skippedSession = true; index += 1; continue }
                    if !arg.hasPrefix("-") || arg == "-" {
                        if skippedSession && preservePromptTags { result.append(arg) }
                        index += 1
                        continue
                    }

                    let width = optionWidth(args, index: index, policy: codexPolicy)
                    let end = min(args.count, index + width)
                    if codexPolicy.variadicOptions.contains(arg),
                       forkCommand.forkIndex > index,
                       forkCommand.forkIndex < end {
                        if forkCommand.forkIndex > index + 1 {
                            result.append(contentsOf: args[index..<forkCommand.forkIndex])
                        }
                        index = forkCommand.forkIndex
                        continue
                    }
                    if codexPolicy.variadicOptions.contains(arg),
                       forkCommand.sessionIndex > index,
                       forkCommand.sessionIndex < end {
                        if forkCommand.sessionIndex > index + 1 {
                            result.append(contentsOf: args[index..<forkCommand.sessionIndex])
                        }
                        index = forkCommand.sessionIndex
                        continue
                    }
                    result.append(contentsOf: args[index..<end])
                    index += width
                }

                return result
            }

            var tail = removingCmuxInjectedCodexHookArguments(args); var preservePositionals = false
            if let forkCommand = codexForkCommand(in: tail) {
                tail = dropForkPositionals(tail, forkCommand: forkCommand); preservePositionals = preservePromptTags
            }
            var policy = codexPolicy; policy.preservePositionals = preservePositionals
            if preservePositionals {
                policy.nonRestorableCommands = []
            }
            return preserveOptions(tail, policy: policy)
        }
        switch kind {
        case "claude":
            return preserveOptions(args, policy: claudePolicy)
        case "codex":
            return preserveOptions(removingCmuxInjectedCodexHookArguments(args), policy: codexPolicy)
        case "codex-fork-replay": return preserveCodexFork(true)
        case "codex-fork-restore": return preserveCodexFork(false)
        case "grok":
            return preserveOptions(args, policy: grokPolicy)
        case "pi", "omp":
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
        case "kiro":
            var tail = args
            if tail.first == "chat" {
                tail.removeFirst()
            } else if let command = tail.first,
                      !command.hasPrefix("-") {
                return nil
            }
            return preserveOptions(tail, policy: kiroPolicy)
        case "antigravity":
            return preserveOptions(args, policy: antigravityPolicy)
        case "opencode":
            var tail = args
            while let first = tail.first {
                let normalized = first.replacingOccurrences(of: "\\", with: "/")
                let isInternalArgument = first == "tui-settings" ||
                    (normalized.contains("/$bunfs/") && normalized.hasSuffix("/tui/worker.js"))
                guard isInternalArgument else { break }
                tail.removeFirst()
            }
            return preserveOptions(tail, policy: openCodePolicy)
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
            guard let preserved = preserveOptions(tail, policy: hermesAgentPolicy) else { return nil }
            return HermesAgentCodexEnvironment.argumentsByReplacingOpenAICodexProvider(preserved)
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

    /// Preserves restorable `claude-teams` `args` with the Teams policy, keeping routing flags while dropping `--tmux` prompt payloads; returns `nil` for unsafe replay shapes.
    public static func preservedClaudeTeamsLaunchArguments(args: [String]) -> [String]? { preserveOptions(args, policy: claudeTeamsPolicy) }

    /// Whether `option` appears as a real Claude *option* in claude-teams launch
    /// `args`. Unlike restore preservation, this does NOT stop at the first
    /// positional — Claude honors options that follow a positional prompt (e.g.
    /// `claude "do x" --dangerously-skip-permissions` enables bypass mode). It reuses
    /// the launch parser's prompt-boundary handling, so `--tmux classic` (a launch
    /// mode) is skipped and scanning continues, while a real `--tmux <prompt>`
    /// payload, a trailing `--`, or a value slot are NOT treated as options. Use this
    /// for trust-boundary opt-in decisions so a flag-shaped token inside the prompt
    /// is never promoted to an option.
    public static func claudeTeamsLaunchHasOption(_ option: String, args: [String]) -> Bool {
        let policy = claudeTeamsPolicy
        var index = 0
        var sink: [String] = []
        while index < args.count {
            let arg = args[index]
            if arg == "--" { return false }
            if !arg.hasPrefix("-") || arg == "-" {
                index += 1
                continue
            }
            let width = optionWidth(args, index: index, policy: policy)
            guard let consumedBoundary = consumePromptBoundaryOption(
                arg, args: args, index: &index, width: width, policy: policy, result: &sink
            ) else {
                return false
            }
            if consumedBoundary { continue }
            if arg == option || arg.hasPrefix(option + "=") { return true }
            index += max(width, 1)
        }
        return false
    }
    public static func removingSavedWorkingDirectoryOptions(
        from args: [String],
        workingDirectory: String?
    ) -> [String] {
        guard let workingDirectory = normalizedWorkingDirectory(workingDirectory) else {
            return args
        }

        let valueOptions: Set<String> = ["--cd", "-C", "--cwd", "--workspace", "-w"]
        let optionPrefixes = valueOptions.map { "\($0)=" }
        var result: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                result.append(contentsOf: args[index...])
                break
            }
            if valueOptions.contains(arg),
               index + 1 < args.count,
               workingDirectoryValue(args[index + 1], matches: workingDirectory) {
                index += 2
                continue
            }
            if let prefix = optionPrefixes.first(where: { arg.hasPrefix($0) }) {
                let value = String(arg.dropFirst(prefix.count))
                if workingDirectoryValue(value, matches: workingDirectory) {
                    index += 1
                    continue
                }
            }
            result.append(arg)
            index += 1
        }
        return result
    }

    private static func normalizedWorkingDirectory(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func workingDirectoryValue(_ value: String, matches workingDirectory: String) -> Bool {
        guard value == workingDirectory else {
            return (value as NSString).expandingTildeInPath == (workingDirectory as NSString).expandingTildeInPath
        }
        return true
    }

    static func runtimeOnlyOptionWidth(_ arg: String) -> Int? {
        if let width = runtimeOnlyOptionWidths[arg] {
            return width
        }
        guard let equals = arg.firstIndex(of: "=") else { return nil }
        return runtimeOnlyOptionWidths[String(arg[..<equals])].map { _ in 1 }
    }

    static func claudeHookSettingsReplacement(_ args: [String], index: Int) -> [String]? {
        let arg = args[index]
        if arg.hasPrefix("--settings=") {
            let value = String(arg.dropFirst("--settings=".count))
            switch claudeHookSettingsReplacementValue(value) {
            case .none:
                return nil
            case .some(.drop):
                return []
            case .some(.settings(let userSettings)):
                return ["--settings=\(userSettings)"]
            }
        }
        guard arg == "--settings", index + 1 < args.count else {
            return nil
        }
        let value = args[index + 1]
        switch claudeHookSettingsReplacementValue(value) {
        case .none:
            return nil
        case .some(.drop):
            return []
        case .some(.settings(let userSettings)):
            return ["--settings", userSettings]
        }
    }

    private static func claudeHookSettingsReplacementValue(_ value: String) -> ClaudeHookSettingsReplacement? {
        if let object = claudeSettingsObject(from: value) {
            guard isClaudeHookSettingsObject(object) else { return nil }
            guard let userSettings = userClaudeSettingsJSON(fromMergedHookSettingsObject: object) else {
                return .drop
            }
            return .settings(userSettings)
        }
        return isLegacyClaudeHookSettingsValue(value) ? .drop : nil
    }

    private static func isLegacyClaudeHookSettingsValue(_ value: String) -> Bool {
        value.contains("claude-hook") || value.contains("hooks claude")
    }

    private static func claudeSettingsObject(from value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func isClaudeHookSettingsObject(_ object: [String: Any]) -> Bool {
        if object["preferredNotifChannel"] as? String == "notifications_disabled" {
            return true
        }
        return containsLegacyClaudeHookSettingsValue(object["hooks"])
    }

    private static func containsLegacyClaudeHookSettingsValue(_ value: Any?) -> Bool {
        switch value {
        case let string as String:
            return isLegacyClaudeHookSettingsValue(string)
        case let array as [Any]:
            return array.contains { containsLegacyClaudeHookSettingsValue($0) }
        case let dictionary as [String: Any]:
            return dictionary.values.contains { containsLegacyClaudeHookSettingsValue($0) }
        default:
            return false
        }
    }

    private static func userClaudeSettingsJSON(fromMergedHookSettingsObject object: [String: Any]) -> String? {
        var object = object
        for key in claudeCmuxSettingsKeys {
            object.removeValue(forKey: key)
        }
        guard !object.isEmpty,
              JSONSerialization.isValidJSONObject(object),
              let userData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: userData, encoding: .utf8)
    }

}
