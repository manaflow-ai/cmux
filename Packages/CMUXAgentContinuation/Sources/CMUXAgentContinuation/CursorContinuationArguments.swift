import Foundation

/// Rewrites Cursor Agent launch argv into the option tail that is safe to replay for resume.
public struct CursorContinuationArguments: Sendable, Equatable {
    private let valueOptions: Set<String>
    private let optionalValueOptions: Set<String>
    private let droppedOptions: Set<String>
    private let droppedOptionPrefixes: [String]
    private let rejectedOptions: Set<String>
    private let rejectedCommands: Set<String>
    private let continuationCommands: Set<String>

    /// Creates a Cursor continuation rewriter.
    public init(
        valueOptions: Set<String> = [
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
            "--worktree-base",
        ],
        optionalValueOptions: Set<String> = [
            "-w",
            "--resume",
            "--worktree",
        ],
        droppedOptions: Set<String> = [
            "--api-key",
            "-H",
            "--header",
            "--continue",
            "--resume",
            "--workspace",
            "-w",
            "--worktree",
            "--worktree-base",
            "--skip-worktree-setup",
        ],
        droppedOptionPrefixes: [String] = [
            "--api-key=",
            "--header=",
            "-H=",
            "--resume=",
            "--workspace=",
            "--worktree=",
            "--worktree-base=",
        ],
        rejectedOptions: Set<String> = [
            "--cloud",
            "--output-format",
            "--print",
            "-p",
            "--stream-partial-output",
        ],
        rejectedCommands: Set<String> = [
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
            "rule",
            "status",
            "uninstall-shell-integration",
            "update",
            "whoami",
        ],
        continuationCommands: Set<String> = [
            "resume",
        ]
    ) {
        self.valueOptions = valueOptions
        self.optionalValueOptions = optionalValueOptions
        self.droppedOptions = droppedOptions
        self.droppedOptionPrefixes = droppedOptionPrefixes
        self.rejectedOptions = rejectedOptions
        self.rejectedCommands = rejectedCommands
        self.continuationCommands = continuationCommands
    }

    /// Returns the replay-safe option tail, preserving unknown option tokens by default.
    public func preservedTail(_ args: [String]) -> [String]? {
        var tail = args
        if tail.first == "agent" {
            tail.removeFirst()
        }
        return rewrite(tail).preserved
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
                if skippingContinuationSession {
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
            if rejectedOptions.contains(optionName(arg)) {
                return .rejected
            }
            if droppedOptionPrefixes.contains(where: { arg.hasPrefix($0) })
                || droppedOptions.contains(optionName(arg)) {
                index += optionWidth(args, index: index)
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
        if optionalValueOptions.contains(arg), isOption(args[index + 1]) {
            return 1
        }
        return 2
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
