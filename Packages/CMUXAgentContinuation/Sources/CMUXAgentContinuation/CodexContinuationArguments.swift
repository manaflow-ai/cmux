import Foundation

/// Rewrites Codex launch argv into the option tail that is safe to replay for resume/fork.
public struct CodexContinuationArguments: Sendable, Equatable {
    private let valueOptions: Set<String>
    private let droppedOptions: Set<String>
    private let droppedOptionPrefixes: [String]
    private let variadicDroppedOptions: Set<String>
    private let rejectedCommands: Set<String>
    private let runtimeOnlyOptions: Set<String>
    private let continuationCommands: Set<String>

    /// Creates a Codex continuation rewriter.
    public init(
        valueOptions: Set<String> = [
            "--add-dir",
            "--ask-for-approval",
            "-a",
            "--cd",
            "-C",
            "--config",
            "-c",
            "--disable",
            "--enable",
            "--image",
            "-i",
            "--local-provider",
            "--model",
            "-m",
            "--profile",
            "-p",
            "--remote",
            "--remote-auth-token-env",
            "--sandbox",
            "-s",
        ],
        droppedOptions: Set<String> = [
            "--all",
            "--image",
            "-i",
            "--last",
            "--remote",
            "--remote-auth-token-env",
        ],
        droppedOptionPrefixes: [String] = [
            "--image=",
            "--remote=",
            "--remote-auth-token-env=",
        ],
        variadicDroppedOptions: Set<String> = [
            "--image",
            "-i",
        ],
        rejectedCommands: Set<String> = [
            "app",
            "app-server",
            "apply",
            "archive",
            "cloud",
            "completion",
            "debug",
            "delete",
            "doctor",
            "exec",
            "exec-server",
            "features",
            "help",
            "login",
            "logout",
            "mcp",
            "mcp-server",
            "plugin",
            "remote-control",
            "review",
            "sandbox",
            "unarchive",
            "update",
        ],
        runtimeOnlyOptions: Set<String> = [
            "--use-system-ca",
        ],
        continuationCommands: Set<String> = [
            "fork",
            "resume",
        ]
    ) {
        self.valueOptions = valueOptions
        self.droppedOptions = droppedOptions
        self.droppedOptionPrefixes = droppedOptionPrefixes
        self.variadicDroppedOptions = variadicDroppedOptions
        self.rejectedCommands = rejectedCommands
        self.runtimeOnlyOptions = runtimeOnlyOptions
        self.continuationCommands = continuationCommands
    }

    /// Returns the replay-safe option tail, preserving unknown option tokens by default.
    public func preservedTail(_ args: [String]) -> [String]? {
        rewrite(args).preserved
    }

    /// Returns the replay-safe option tail for a captured `fork` launch.
    public func preservedForkTail(_ args: [String]) -> [String]? {
        rewrite(args).preserved
    }

    private func rewrite(_ args: [String]) -> RewriteResult {
        var result: [String] = []
        var index = 0
        var previousUnknownOptionNeedsValue = false
        var skippingContinuationSession = false
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                break
            }

            if !isOption(arg) {
                if continuationCommands.contains(arg) {
                    index += 1
                    skippingContinuationSession = true
                    previousUnknownOptionNeedsValue = false
                    continue
                }
                if rejectedCommands.contains(arg) {
                    return .rejected
                }
                if skippingContinuationSession, looksLikeSessionIdentifier(arg) {
                    index += 1
                    while index < args.count, !isOption(args[index]) {
                        index += 1
                    }
                    skippingContinuationSession = false
                    previousUnknownOptionNeedsValue = false
                    continue
                }
                if previousUnknownOptionNeedsValue,
                   containsContinuationCommand(after: index, in: args) {
                    result.append(arg)
                    index += 1
                    previousUnknownOptionNeedsValue = false
                    continue
                }
                break
            }

            previousUnknownOptionNeedsValue = false
            if droppedOptionPrefixes.contains(where: { arg.hasPrefix($0) }) || runtimeOnlyOption(arg) {
                index += droppedOptionWidth(args, index: index)
                continue
            }
            if droppedOptions.contains(optionName(arg)) {
                index += droppedOptionWidth(args, index: index)
                continue
            }

            if arg.contains("=") {
                result.append(arg)
                index += 1
                continue
            }

            if valueOptions.contains(arg) {
                let width = optionWidth(args, index: index)
                result.append(contentsOf: args[index..<min(args.count, index + width)])
                index += width
                continue
            }

            result.append(arg)
            previousUnknownOptionNeedsValue = true
            index += 1
        }
        return .accepted(result)
    }

    private func containsContinuationCommand(after start: Int, in args: [String]) -> Bool {
        guard start < args.count else { return false }
        var index = start
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                return false
            }
            if continuationCommands.contains(arg) {
                return true
            }
            index += 1
        }
        return false
    }

    private func optionWidth(_ args: [String], index: Int) -> Int {
        let arg = args[index]
        if arg.contains("=") {
            return 1
        }
        guard valueOptions.contains(arg), index + 1 < args.count else {
            return 1
        }
        return 2
    }

    private func droppedOptionWidth(_ args: [String], index: Int) -> Int {
        let arg = args[index]
        if arg.contains("=") {
            return 1
        }
        guard variadicDroppedOptions.contains(arg) else {
            return optionWidth(args, index: index)
        }
        var end = index + 1
        while end < args.count, !isOption(args[end]) {
            end += 1
        }
        return max(1, end - index)
    }

    private func looksLikeSessionIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return false }
        if trimmed.hasPrefix("019") {
            return true
        }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) } && trimmed.contains("-")
    }

    private func runtimeOnlyOption(_ arg: String) -> Bool {
        runtimeOnlyOptions.contains(optionName(arg))
    }

    private func optionName(_ arg: String) -> String {
        guard let equals = arg.firstIndex(of: "=") else { return arg }
        return String(arg[..<equals])
    }

    private func isOption(_ arg: String) -> Bool {
        arg.hasPrefix("-") && arg != "-"
    }

    private enum RewriteResult: Equatable {
        case accepted([String])
        case rejected

        var preserved: [String]? {
            switch self {
            case .accepted(let args):
                return args
            case .rejected:
                return nil
            }
        }
    }
}
