import Foundation

func preservedCodexLaunchArguments(args: [String]) -> [String]? {
    let args = removingCmuxInjectedCodexHookArguments(args)
    if let forkCommand = codexForkCommand(in: args) {
        return CodexForkLaunchCapture(
            args: args,
            forkIndex: forkCommand.forkIndex,
            sessionIndex: forkCommand.sessionIndex,
            preserveOptions: AgentLaunchSanitizer.preserveOptions
        ).arguments()
    }
    return AgentLaunchSanitizer.preservedArguments(kind: "codex", args: args)
}

func removingCmuxInjectedCodexHookArguments(_ args: [String]) -> [String] {
    guard let injectedPrefixEnd = cmuxInjectedCodexHookArgumentPrefixEnd(args) else { return args }
    return Array(args.dropFirst(injectedPrefixEnd))
}

func codexReplayExecutable(capturedExecutable: String, launchTail: [String]) -> String {
    cmuxInjectedCodexHookArgumentPrefixEnd(launchTail) == nil ? capturedExecutable : "codex"
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
    if index < args.count, args[index] == "--dangerously-bypass-hook-trust" {
        index += 1
    }

    var strippedHookConfig = false
    while index < args.count {
        let arg = args[index]
        if isCmuxInjectedCodexHookConfigOption(arg) {
            strippedHookConfig = true
            index += 1
            continue
        }
        if (arg == "-c" || arg == "--config"),
           index + 1 < args.count,
           isCmuxInjectedCodexHookConfigValue(args[index + 1]) {
            strippedHookConfig = true
            index += 2
            continue
        }
        break
    }
    return strippedHookConfig ? index : nil
}

private func isCmuxInjectedCodexHookConfigOption(_ arg: String) -> Bool {
    for prefix in ["-c=", "--config="] where arg.hasPrefix(prefix) {
        return isCmuxInjectedCodexHookConfigValue(String(arg.dropFirst(prefix.count)))
    }
    return false
}

private func isCmuxInjectedCodexHookConfigValue(_ value: String) -> Bool {
    guard let equals = value.firstIndex(of: "=") else { return false }
    let key = String(value[..<equals])
    guard key.hasPrefix("hooks.") else { return false }
    let eventName = String(key.dropFirst("hooks.".count))
    guard let event = codexWrapperInjectedHookEvents[eventName] else { return false }

    let body = String(value[value.index(after: equals)...])
    let prefix = "[{hooks=[{type=\"command\",command='''"
    guard let suffix = event.timeoutMs
        .map({ "''',timeout=\($0)}]}]" })
        .first(where: { body.hasSuffix($0) }) else {
        return false
    }
    guard body.hasPrefix(prefix), body.hasSuffix(suffix) else { return false }
    let command = String(body.dropFirst(prefix.count).dropLast(suffix.count))
    return isCmuxCodexHookCommand(command, subcommand: event.cmuxSubcommand)
}

private let codexWrapperInjectedHookEvents: [String: (cmuxSubcommand: String, timeoutMs: [Int])] = [
    "SessionStart": ("session-start", [10000]),
    "UserPromptSubmit": ("prompt-submit", [10000]),
    "Stop": ("stop", [10000]),
    "SessionStop": ("stop", [10000]),
    "PreToolUse": ("pre-tool-use", [120000, 10000]),
    "PostToolUse": ("post-tool-use", [10000]),
    "PermissionRequest": ("notification", [120000]),
    "Notification": ("notification", [10000]),
]

private func isCmuxCodexHookCommand(_ command: String, subcommand: String) -> Bool {
    let normalized = command.replacingOccurrences(of: "\\", with: "/")
    let subcommands = [subcommand] + (codexWrapperInjectedHookSubcommandAliases[subcommand] ?? [])
    for candidate in subcommands {
        if normalized.contains("/.cmux/hooks/cmux-codex-hook-\(candidate).sh") {
            return true
        }
        if command.contains("cmux-codex-hook") && command.contains("hooks codex \(candidate)") {
            return true
        }
    }
    return false
}

private let codexWrapperInjectedHookSubcommandAliases: [String: [String]] = [
    "prompt-submit": ["user-prompt-submit"],
    "stop": ["session-stop"],
]

/// The agent whose cmux wrapper injected hook arguments into captured argv, or
/// nil when no cmux-injected marker is present. A non-nil name is the
/// deterministic signal that cmux's PATH shim wrapper for that agent spawned
/// this process from a bare agent name (vs the user launching a script or
/// explicit path directly).
func cmuxWrapperInjectedAgentNameFromArgumentPrefix(_ args: [String]) -> String? {
    if cmuxInjectedCodexHookArgumentPrefixEnd(args) != nil { return "codex" }
    if cmuxInjectedClaudeHookSettingsArgumentPrefixEnd(args) != nil { return "claude" }
    return nil
}

private func cmuxInjectedClaudeHookSettingsArgumentPrefixEnd(_ args: [String]) -> Int? {
    var index = 0
    if index + 1 < args.count,
       args[index] == "--session-id",
       !args[index + 1].hasPrefix("-") {
        index += 2
    } else if index < args.count,
              args[index].hasPrefix("--session-id=") {
        index += 1
    }
    guard index < args.count else { return nil }

    let first = args[index]
    if first == "--settings", index + 1 < args.count {
        return isCmuxInjectedClaudeHookSettingsValue(args[index + 1]) ? index + 2 : nil
    }
    if first.hasPrefix("--settings="),
       isCmuxInjectedClaudeHookSettingsValue(String(first.dropFirst("--settings=".count))) {
        return index + 1
    }
    return nil
}

/// Matches only the live cmux Claude wrapper's injected settings shape. This is
/// used as executable-identity proof, so unlike the resume sanitizer's legacy
/// stripping path it must not accept arbitrary user JSON that merely mentions
/// `hooks claude` or `claude-hook`.
private func isCmuxInjectedClaudeHookSettingsValue(_ value: String) -> Bool {
    guard let data = value.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["preferredNotifChannel"] as? String == "notifications_disabled",
          let hooks = object["hooks"] else {
        return false
    }
    return containsCmuxClaudeWrapperHookCommand(hooks)
}

private func containsCmuxClaudeWrapperHookCommand(_ value: Any) -> Bool {
    switch value {
    case let string as String:
        return isCmuxClaudeWrapperHookCommand(string)
    case let array as [Any]:
        return array.contains { containsCmuxClaudeWrapperHookCommand($0) }
    case let dictionary as [String: Any]:
        return dictionary.values.contains { containsCmuxClaudeWrapperHookCommand($0) }
    default:
        return false
    }
}

private func isCmuxClaudeWrapperHookCommand(_ command: String) -> Bool {
    let normalized = command.replacingOccurrences(of: "\\", with: "/")
    return normalized.contains("CMUX_CLAUDE_HOOK_CMUX_BIN") &&
        normalized.contains(" hooks claude ")
}
