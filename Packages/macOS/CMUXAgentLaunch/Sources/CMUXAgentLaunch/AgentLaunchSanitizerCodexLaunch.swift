import Foundation

func preservedCodexLaunchArguments(args: [String], stripCmuxHooks: Bool = true) -> [String]? {
    let args = stripCmuxHooks ? removingCmuxInjectedCodexHookArguments(args) : args
    if let forkCommand = codexForkCommand(in: args) {
        return CodexForkLaunchCapture(
            args: args,
            forkIndex: forkCommand.forkIndex,
            sessionIndex: forkCommand.sessionIndex,
            preserveOptions: AgentLaunchSanitizer.preserveOptions
        ).arguments()
    }
    return AgentLaunchSanitizer.preserveOptions(args, policy: AgentLaunchSanitizer.codexPolicy)
}

func preservedCodexForkArguments(
    args: [String],
    preservePromptTags: Bool,
    stripCmuxHooks: Bool = true
) -> [String]? {
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

            let width = AgentLaunchSanitizer.optionWidth(args, index: index, policy: AgentLaunchSanitizer.codexPolicy)
            let end = min(args.count, index + width)
            if AgentLaunchSanitizer.codexPolicy.variadicOptions.contains(arg),
               forkCommand.forkIndex > index,
               forkCommand.forkIndex < end {
                if forkCommand.forkIndex > index + 1 {
                    result.append(contentsOf: args[index..<forkCommand.forkIndex])
                }
                index = forkCommand.forkIndex
                continue
            }
            if AgentLaunchSanitizer.codexPolicy.variadicOptions.contains(arg),
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

    var tail = stripCmuxHooks ? removingCmuxInjectedCodexHookArguments(args) : args
    var preservePositionals = false
    if let forkCommand = codexForkCommand(in: tail) {
        tail = dropForkPositionals(tail, forkCommand: forkCommand)
        preservePositionals = preservePromptTags
    }
    var policy = AgentLaunchSanitizer.codexPolicy
    policy.preservePositionals = preservePositionals
    if preservePositionals {
        policy.nonRestorableCommands = []
    }
    return AgentLaunchSanitizer.preserveOptions(tail, policy: policy)
}

func removingCmuxInjectedCodexHookArguments(_ args: [String]) -> [String] {
    guard let injectedPrefixEnd = cmuxInjectedCodexHookArgumentPrefixEnd(args) else { return args }
    return Array(args.dropFirst(injectedPrefixEnd))
}

func codexReplayExecutable(capturedExecutable: String, launchTail _: [String]) -> String {
    // Codex hook config is normal user-controllable argv. It is safe to strip
    // cmux's injected hook prefix from replay options, but it is not identity
    // proof that the captured executable came from cmux's PATH shim.
    capturedExecutable
}

struct CodexForkCommand {
    let forkIndex: Int
    let sessionIndex: Int
}

func codexForkCommand(in args: [String]) -> CodexForkCommand? {
    let codexPolicy = AgentLaunchSanitizer.codexPolicy
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
        let width = AgentLaunchSanitizer.optionWidth(args, index: index, policy: codexPolicy)
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

// MARK: - File-scope codex launch helpers
//
// Pure helpers used only by this file. They live at file scope rather than as
// static members so the `AgentLaunchSanitizer` extension surface stays limited
// to the API its cross-file consumers (launch preservation, capture, tests)
// actually call.

private func codexForkCommandSessionIndex(_ args: [String], forkIndex: Int) -> Int? {
    let codexPolicy = AgentLaunchSanitizer.codexPolicy
    var index = forkIndex + 1
    while index < args.count {
        let argument = args[index]
        if argument == "--" {
            return nil
        }
        if !argument.hasPrefix("-") || argument == "-" {
            return looksLikeCodexSessionIdentifier(argument) ? index : nil
        }
        let width = AgentLaunchSanitizer.optionWidth(args, index: index, policy: codexPolicy)
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

private func looksLikeCodexSessionIdentifier(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 20 else { return false }
    if trimmed.hasPrefix("019") {
        return true
    }
    let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
    return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) } && trimmed.contains("-")
}

private func cmuxInjectedCodexHookArgumentPrefixEnd(_ args: [String]) -> Int? {
    var index = 0
    if index + 1 < args.count, args[index] == "--enable", args[index + 1] == "hooks" {
        index += 2
    } else if index < args.count, args[index] == "--enable=hooks" {
        index += 1
    } else {
        return nil
    }
    guard index < args.count, args[index] == "--dangerously-bypass-hook-trust" else {
        return nil
    }
    index += 1

    // New wrappers prepend the current complete ordered block in one operation.
    // Exact compatibility schemas keep saved commands replayable across
    // upgrades. Requiring one registered structure distinguishes cmux
    // injection from later user hook config.
    for schema in CodexHookInjectionSchema.recognized {
        var candidateIndex = index
        var matches = true
        for event in schema.events {
            guard let config = codexHookConfigValue(in: args, at: candidateIndex),
                  isCmuxInjectedCodexHookConfigValue(config.value, event: event)
            else {
                matches = false
                break
            }
            candidateIndex = config.nextIndex
        }
        if matches {
            return candidateIndex
        }
    }
    return nil
}

private func codexHookConfigValue(
    in args: [String],
    at index: Int
) -> (value: String, nextIndex: Int)? {
    guard index < args.count else { return nil }
    let argument = args[index]
    for prefix in ["-c=", "--config="] where argument.hasPrefix(prefix) {
        return (String(argument.dropFirst(prefix.count)), index + 1)
    }
    guard (argument == "-c" || argument == "--config"), index + 1 < args.count else {
        return nil
    }
    return (args[index + 1], index + 2)
}

private func isCmuxInjectedCodexHookConfigValue(
    _ value: String,
    event: CodexHookInjectionEvent
) -> Bool {
    guard let equals = value.firstIndex(of: "=") else { return false }
    let key = String(value[..<equals])
    guard key == "hooks.\(event.agentEvent)" else { return false }

    let body = String(value[value.index(after: equals)...])
    let prefix = "[{hooks=[{type=\"command\",command='''"
    let suffix = "''',timeout=\(event.timeoutMs)}]}]"
    guard body.hasPrefix(prefix), body.hasSuffix(suffix) else { return false }
    let command = String(body.dropFirst(prefix.count).dropLast(suffix.count))
    return isCmuxCodexHookCommand(command, subcommand: event.cmuxSubcommand)
}

private func isCmuxCodexHookCommand(_ command: String, subcommand: String) -> Bool {
    let scriptFilename = cmuxCodexHookScriptFilename(from: command)
    let subcommands = [subcommand] + (codexWrapperInjectedHookSubcommandAliases[subcommand] ?? [])
    for candidate in subcommands {
        if let scriptFilename,
           CodexHookScriptName(filename: scriptFilename)?.subcommand == candidate {
            return true
        }
        // Keep the legacy inline matcher conservative. A quoted script path is
        // handled structurally above; this fallback is only for old generated
        // shell snippets and must not treat escaped user commands as cmux-owned.
        if !command.contains("\\"),
           command.contains("cmux-codex-hook") && command.contains("hooks codex \(candidate)") {
            return true
        }
    }
    return false
}

private func cmuxCodexHookScriptFilename(from command: String) -> String? {
    guard let scriptPath = CodexHookScriptName.scriptPath(fromShellCommand: command) else {
        return nil
    }

    let url = URL(fileURLWithPath: scriptPath, isDirectory: false).standardizedFileURL
    // A generated command is the complete executable path. Canonical shell
    // quoting already proves that boundary whitespace belongs to the path; the
    // legacy bare form still needs conservative validation because it cannot
    // distinguish a complete path token from a malformed command.
    guard url.path == scriptPath else { return nil }
    if !command.hasPrefix("'"),
       scriptPath.unicodeScalars.contains(where: {
           CharacterSet.controlCharacters.contains($0)
       }) {
        return nil
    }
    if !command.hasPrefix("'"),
       !url.pathComponents.allSatisfy({
           $0 == $0.trimmingCharacters(in: .whitespaces)
       }) {
        return nil
    }
    let directoryComponents = url.deletingLastPathComponent().pathComponents
    guard directoryComponents.count >= 2,
          Array(directoryComponents.suffix(2)) == [".cmux", "hooks"]
    else {
        return nil
    }
    return url.lastPathComponent
}

private let codexWrapperInjectedHookSubcommandAliases: [String: [String]] = [
    "prompt-submit": ["user-prompt-submit"],
    "stop": ["session-stop"],
]

/// The agent whose cmux wrapper injected identity-proving hook arguments into
/// captured argv, or nil when no safe marker is present. Hook config in argv is
/// normal user-controllable CLI input, so it is intentionally not used as
/// executable identity proof here.
func cmuxWrapperInjectedAgentNameFromArgumentPrefix(_: [String]) -> String? {
    return nil
}
