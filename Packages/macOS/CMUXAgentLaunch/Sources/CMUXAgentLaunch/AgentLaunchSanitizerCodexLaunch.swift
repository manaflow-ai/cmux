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
        guard containsCmuxInjectedCodexHookConfig(args) else { return args }
        var result: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if isCmuxInjectedCodexHookConfigOption(arg) {
                index += 1
                continue
            }
            if (arg == "-c" || arg == "--config"),
               index + 1 < args.count,
               isCmuxInjectedCodexHookConfigValue(args[index + 1]) {
                index += 2
                continue
            }
            if arg == "--enable", index + 1 < args.count, args[index + 1] == "hooks" {
                index += 2
                continue
            }
            if arg == "--enable=hooks" || arg == "--dangerously-bypass-hook-trust" {
                index += 1
                continue
            }
            result.append(arg)
            index += 1
        }
        return result
    }

    /// Unwraps a node/bun-hosted known agent to a bare agent executable argv.
    ///
    /// Captured foreground argv may look like `node .../bin/codex <flags>` when
    /// cmux launched the agent through a JavaScript runtime wrapper. Returning a
    /// bare executable name such as `codex` deliberately routes replay through
    /// the per-surface PATH shim and cmux wrapper, so hooks are re-injected fresh
    /// instead of persisting the runtime script path.
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
        let scriptName = (argv[scriptIndex] as NSString).lastPathComponent
        let matchedName: String
        if isKnownAgentExecutableName(scriptName) {
            matchedName = scriptName
        } else if let strippedName = scriptName.removingSingleJavaScriptExtension(),
                  isKnownAgentExecutableName(strippedName) {
            matchedName = strippedName
        } else {
            return nil
        }
        return [matchedName] + Array(argv.dropFirst(scriptIndex + 1))
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

    static func codexForkCommandSessionIndex(_ args: [String], forkIndex: Int) -> Int? {
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

    static func looksLikeCodexSessionIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return false }
        if trimmed.hasPrefix("019") {
            return true
        }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) } && trimmed.contains("-")
    }

    private static func containsCmuxInjectedCodexHookConfig(_ args: [String]) -> Bool {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if isCmuxInjectedCodexHookConfigOption(arg) {
                return true
            }
            if (arg == "-c" || arg == "--config"),
               index + 1 < args.count,
               isCmuxInjectedCodexHookConfigValue(args[index + 1]) {
                return true
            }
            index += 1
        }
        return false
    }

    private static func isCmuxInjectedCodexHookConfigOption(_ arg: String) -> Bool {
        for prefix in ["-c=", "--config="] where arg.hasPrefix(prefix) {
            return isCmuxInjectedCodexHookConfigValue(String(arg.dropFirst(prefix.count)))
        }
        return false
    }

    private static func isCmuxInjectedCodexHookConfigValue(_ value: String) -> Bool {
        value.hasPrefix("hooks.") && value.contains("cmux-codex-hook")
    }

    private static func javaScriptRuntimeScriptArgumentIndex(_ argv: [String]) -> Int? {
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

    private static func nodeOptionConsumesScript(_ argument: String) -> Bool {
        let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        switch option {
        case "-e", "--eval", "-p", "--print", "-c", "--check":
            return true
        default:
            return false
        }
    }

    private static func nodeOptionValueCount(_ argument: String) -> Int {
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
}

private extension String {
    func removingSingleJavaScriptExtension() -> String? {
        for suffix in [".js", ".mjs", ".cjs"] where hasSuffix(suffix) {
            return String(dropLast(suffix.count))
        }
        return nil
    }
}
