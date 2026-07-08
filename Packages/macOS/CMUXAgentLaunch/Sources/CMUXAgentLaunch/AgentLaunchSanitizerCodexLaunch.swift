import Foundation

extension AgentLaunchSanitizer {
    static func preservedCodexLaunchArguments(args: [String]) -> [String]? {
        let args = removingCmuxInjectedCodexHookArguments(args)
        if let forkCommand = codexForkCommand(in: args) {
            return CodexForkLaunchCapture(
                args: args,
                forkIndex: forkCommand.forkIndex,
                sessionIndex: forkCommand.sessionIndex,
                preserveOptions: preserveOptions
            ).arguments()
        }
        return preservedArguments(kind: "codex", args: args)
    }

    static func removingCmuxInjectedCodexHookArguments(_ args: [String]) -> [String] {
        guard let injectedPrefixEnd = cmuxInjectedCodexHookArgumentPrefixEnd(args) else { return args }
        return Array(args.dropFirst(injectedPrefixEnd))
    }

    /// Unwraps a node/bun-hosted known agent to a bare agent executable argv.
    ///
    /// Captured foreground argv may look like `node .../bin/codex <flags>` when
    /// cmux launched the agent through a JavaScript runtime wrapper. Returning a
    /// bare executable name such as `codex` deliberately routes replay through
    /// the per-surface PATH shim and cmux wrapper, so hooks are re-injected fresh
    /// instead of persisting the runtime script path.
    ///
    /// A basename match alone is not enough: a user's own script named like an
    /// agent (`node ./tools/claude.js`, or a project-local pinned
    /// `node_modules` install launched directly) must never be rewritten into
    /// whatever the bare name resolves to on PATH. The deterministic
    /// launch-time proof that the cmux wrapper spawned this process is the
    /// wrapper's own injected hook arguments in the argv: cmux only injects
    /// them when the user invoked the agent by bare name through the
    /// per-surface PATH shim, so replaying the bare name reproduces that
    /// launch exactly. Argv without the marker keeps its original form.
    ///
    /// The marker also identifies which wrapper injected it, so when the
    /// script basename is not itself an agent name (Claude Code's real npm
    /// entrypoint is `.../@anthropic-ai/claude-code/cli.js`), the agent name
    /// derived from the marker is used — but only when the script also lives
    /// inside that agent's own npm package directory, so hook-looking argv
    /// contents on an unrelated script can never rewrite it into an agent.
    /// Basename wins first so a wrapped agent that shares another agent's
    /// hook plumbing still unwraps to its own name.
    public static func unwrappedJavaScriptRuntimeAgentArgv(
        _ argv: [String],
        isKnownAgentExecutableName: (String) -> Bool
    ) -> [String]? {
        guard let executable = argv.first else { return nil }
        let runtimeName = (executable as NSString).lastPathComponent.lowercased()
        guard runtimeName == "node" || runtimeName == "bun",
              let scriptIndex = javaScriptRuntimeScriptArgumentIndex(argv) else {
            return nil
        }
        let scriptTail = Array(argv.dropFirst(scriptIndex + 1))
        guard let markerAgentName = cmuxWrapperInjectedAgentNameFromArgumentPrefix(scriptTail) else {
            return nil
        }
        let scriptName = (argv[scriptIndex] as NSString).lastPathComponent
        let matchedName: String
        if isKnownAgentExecutableName(scriptName) {
            matchedName = scriptName
        } else if let strippedName = scriptName.removingSingleJavaScriptExtension(),
                  isKnownAgentExecutableName(strippedName) {
            matchedName = strippedName
        } else if isKnownAgentExecutableName(markerAgentName),
                  scriptPathIsAgentPackageEntrypoint(argv[scriptIndex], agentName: markerAgentName) {
            matchedName = markerAgentName
        } else {
            return nil
        }
        return [matchedName] + scriptTail
    }

    /// Whether captured argv carries cmux wrapper-injected hook arguments for
    /// any known agent — the deterministic launch-time proof that cmux's
    /// per-surface PATH shim wrapper spawned this process from a bare agent
    /// name. Capture uses this to save the bare name instead of the resolved
    /// absolute binary path, so replay routes back through the shim and hooks
    /// are re-injected fresh.
    public static func containsCmuxWrapperInjectedHookArguments(_ argv: [String]) -> Bool {
        guard !argv.isEmpty else { return false }
        return cmuxWrapperInjectedAgentNameFromArgumentPrefix(Array(argv.dropFirst())) != nil
    }

    struct CodexForkCommand {
        let forkIndex: Int
        let sessionIndex: Int
    }

    static func codexForkCommand(in args: [String]) -> CodexForkCommand? {
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
private func cmuxWrapperInjectedAgentNameFromArgumentPrefix(_ args: [String]) -> String? {
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

/// Mirrors the claude wrapper's injected-settings markers used by
/// `AgentLaunchSanitizer`'s hook-settings replacement (`claude-hook` script
/// paths / `hooks claude` subcommands).
private func isCmuxInjectedClaudeHookSettingsValue(_ value: String) -> Bool {
    value.contains("claude-hook") || value.contains("hooks claude")
}

/// The npm package directory each marker agent's runtime entrypoint lives in.
/// The marker-derived fallback name is only trusted when the script path sits
/// inside its agent's own package, so an unrelated script whose argv happens
/// to contain hook-looking contents is never rewritten into an agent command.
private let cmuxWrapperAgentPackageDirectories: [String: String] = [
    "codex": "node_modules/@openai/codex/",
    "claude": "node_modules/@anthropic-ai/claude-code/",
]

private func scriptPathIsAgentPackageEntrypoint(_ path: String, agentName: String) -> Bool {
    guard let packageDirectory = cmuxWrapperAgentPackageDirectories[agentName] else { return false }
    return path.contains(packageDirectory)
}

private func javaScriptRuntimeScriptArgumentIndex(_ argv: [String]) -> Int? {
    var index = 1
    while index < argv.count {
        let argument = argv[index]
        if argument == "--" {
            let nextIndex = index + 1
            return nextIndex < argv.count ? nextIndex : nil
        }
        if argument.hasPrefix("-") {
            if nodeOptionConsumesScript(argument) {
                return nil
            }
            index += 1 + nodeOptionValueCount(argument)
            continue
        }
        return index
    }
    return nil
}

private func nodeOptionConsumesScript(_ argument: String) -> Bool {
    let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
    switch option {
    case "-e", "--eval", "-p", "--print", "-c", "--check":
        return true
    default:
        return false
    }
}

private func nodeOptionValueCount(_ argument: String) -> Int {
    if argument.contains("=") {
        return 0
    }
    switch argument {
    case "-r", "--require", "--import", "--loader", "--experimental-loader",
         "--conditions", "-C", "--title":
        return 1
    default:
        return 0
    }
}

private extension String {
    func removingSingleJavaScriptExtension() -> String? {
        for suffix in [".js", ".mjs", ".cjs"] where hasSuffix(suffix) {
            return String(dropLast(suffix.count))
        }
        return nil
    }
}
