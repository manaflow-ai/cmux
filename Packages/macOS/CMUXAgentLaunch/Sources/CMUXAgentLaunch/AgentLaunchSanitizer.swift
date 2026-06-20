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
        switch kind {
        case "claude":
            return preserveOptions(args, policy: claudePolicy)
        case "codex":
            return preserveOptions(args, policy: codexPolicy)
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
                let isInternalArgument = first == "tui-settings" || (normalized.contains("/$bunfs/") &&
                    normalized.contains("/src/cli/cmd/tui/worker.js"))
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
    public static func preservedCodexForkArguments(args: [String]) -> [String]? {
        var tail = args
        if let forkCommand = codexForkCommand(in: tail) {
            tail = dropCodexForkPositionals(tail, forkCommand: forkCommand)
        }
        return preserveOptions(tail, policy: codexPolicy)
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

    private static func preservedCodexLaunchArguments(args: [String]) -> [String]? {
        if codexForkCommand(in: args) != nil {
            return preservedCodexForkArguments(args: args)
        }
        return preservedArguments(kind: "codex", args: args)
    }

    private struct CodexForkCommand {
        let forkIndex: Int
        let sessionIndex: Int
    }

    private static func codexForkCommand(in args: [String]) -> CodexForkCommand? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                return nil
            }
            if !isOptionToken(arg) || arg == "-" {
                guard arg == "fork",
                      let sessionIndex = codexForkCommandSessionIndex(args, forkIndex: index) else {
                    return nil
                }
                return CodexForkCommand(forkIndex: index, sessionIndex: sessionIndex)
            }
            let width = optionWidth(args, index: index, policy: codexPolicy)
            if codexPolicy.variadicOptions.contains(arg) {
                let end = min(args.count, index + width)
                if index + 2 < end {
                    for candidateIndex in (index + 2)..<end where args[candidateIndex] == "fork" {
                        if let sessionIndex = codexForkCommandSessionIndex(args, forkIndex: candidateIndex) {
                            return CodexForkCommand(forkIndex: candidateIndex, sessionIndex: sessionIndex)
                        }
                    }
                }
            }
            index += width
        }
        return nil
    }

    private static func codexForkCommandSessionIndex(_ args: [String], forkIndex: Int) -> Int? {
        var index = forkIndex + 1
        while index < args.count {
            let argument = args[index]
            if argument == "--" {
                return nil
            }
            if !argument.hasPrefix("-") || argument == "-" {
                return looksLikeCodexSessionIdentifier(argument) ? index : nil
            }
            let width = optionWidth(args, index: index, policy: codexPolicy)
            if codexPolicy.variadicOptions.contains(argument) {
                let end = min(args.count, index + width)
                if index + 2 < end {
                    for candidateIndex in (index + 2)..<end {
                        if looksLikeCodexSessionIdentifier(args[candidateIndex]) {
                            return candidateIndex
                        }
                    }
                }
            }
            index += width
        }
        return nil
    }

    private static func looksLikeCodexSessionIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return false }
        if trimmed.hasPrefix("019") {
            return true
        }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) } && trimmed.contains("-")
    }

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
                    skippingResumePositionals = false
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

            let runtimeOnlyWidth = runtimeOnlyOptionWidth(arg)
            let width = runtimeOnlyWidth ?? optionWidth(args, index: index, policy: policy)
            if runtimeOnlyWidth != nil || shouldDropOption(arg, droppedOptions: policy.droppedOptions) {
                index += width
                continue
            }

            if policy.skipClaudeHookSettings,
               let replacement = claudeHookSettingsReplacement(args, index: index) {
                result.append(contentsOf: replacement)
                index += width
                continue
            }
            guard let consumedPromptBoundary = consumePromptBoundaryOption(arg, args: args, index: &index, width: width, policy: policy, result: &result) else { return nil }
            if consumedPromptBoundary { continue }
            result.append(contentsOf: args[index..<min(args.count, index + width)])
            index += width
        }

        return result
    }

    private static func dropCodexForkPositionals(_ args: [String], forkCommand: CodexForkCommand) -> [String] {
        var result: [String] = []
        var index = 0

        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                break
            }
            if index == forkCommand.forkIndex {
                index += 1
                continue
            }
            if index == forkCommand.sessionIndex {
                index += 1
                while index < args.count, !args[index].hasPrefix("-") {
                    index += 1
                }
                continue
            }
            if !arg.hasPrefix("-") || arg == "-" {
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

    private static func shouldDropOption(_ arg: String, droppedOptions: Set<String>) -> Bool {
        if droppedOptions.contains(arg) { return true }
        guard let equals = arg.firstIndex(of: "=") else { return false }
        return droppedOptions.contains(String(arg[..<equals]))
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

    private static func runtimeOnlyOptionWidth(_ arg: String) -> Int? {
        if let width = runtimeOnlyOptionWidths[arg] {
            return width
        }
        guard let equals = arg.firstIndex(of: "=") else { return nil }
        return runtimeOnlyOptionWidths[String(arg[..<equals])].map { _ in 1 }
    }

    private static func optionWidth(
        _ args: [String],
        index: Int,
        policy: Policy,
        stopVariadicAtPositionals: Set<String> = []
    ) -> Int {
        let arg = args[index]
        if arg.contains("=") {
            return 1
        }
        if policy.optionalValueOptions.contains(arg) {
            guard index + 1 < args.count else { return 1 }
            let value = args[index + 1]
            if let choices = policy.optionalValueChoices[arg] { return choices.contains(value) ? 2 : 1 }
            let following = index + 2 < args.count ? args[index + 2] : nil
            if policy.greedyOptionalValueOptions.contains(arg),
               looksLikeGreedyOptionalValue(value) { return 2 }
            guard looksLikeOptionalValue(value, following: following) else { return 1 }
            return 2
        }
        guard policy.valueOptions.contains(arg), index + 1 < args.count else { return 1 }
        if policy.variadicOptions.contains(arg) {
            var end = index + 1
            while end < args.count,
                  !args[end].hasPrefix("-"),
                  !stopVariadicAtPositionals.contains(args[end]) {
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
        return following == nil || value.contains(",") || (following?.hasPrefix("-") == true)
    }

    private static func claudeHookSettingsReplacement(_ args: [String], index: Int) -> [String]? {
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
