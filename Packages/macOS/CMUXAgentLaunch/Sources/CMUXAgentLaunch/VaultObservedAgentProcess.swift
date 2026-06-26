import Foundation

/// A `Sendable` snapshot of one observed agent process (its reported name,
/// executable path, argument vector, and environment) plus the heuristics that
/// classify it as a `claude`, `codex`, or `opencode` invocation. The classifiers
/// peer through `node`/`bun` JavaScript-runtime wrappers to the underlying agent
/// script so a `node …/.claude/cli.js` process still reads as claude, while
/// `sr`/`sh` shell wrappers are excluded.
public struct VaultObservedAgentProcess: Sendable {
    /// The process name as reported by the process snapshot.
    public let processName: String
    /// The absolute executable path, when the snapshot resolved one.
    public let processPath: String?
    /// The captured argument vector, argv[0] first.
    public let arguments: [String]
    /// The captured process environment.
    public let environment: [String: String]

    /// Creates an observed-process value from a captured process snapshot.
    public init(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) {
        self.processName = processName
        self.processPath = processPath
        self.arguments = arguments
        self.environment = environment
    }

    /// The de-duplicated executable basenames implied by the process name,
    /// executable path, and argv[0], in that order.
    public var executableBasenames: [String] {
        var names: [String] = []
        if !processName.isEmpty { names.append(processName) }
        if let processPath, !processPath.isEmpty { names.append((processPath as NSString).lastPathComponent) }
        if let first = arguments.first, !first.isEmpty { names.append((first as NSString).lastPathComponent) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// True when the process identity or a node-script argument looks like opencode.
    public var isOpenCodeProcess: Bool {
        processIdentityLooksLikeOpenCode || openCodeExecutableArgumentIndex != nil
    }

    /// True for a real `claude` process: the binary basename is `claude`
    /// (`~/.local/bin/claude` symlink), or a node/bun runtime running claude
    /// (`node …/.claude/cli.js`, `…/claude/versions/…`). Mirrors the live-PID
    /// matcher `liveProcessExecutableMatchesRecordedAgent`. A `sr claude` / shell
    /// wrapper has argv[0] basename `sr`/`sh` and is excluded.
    public var isClaudeProcess: Bool {
        if executableBasenames.contains(where: { $0.lowercased() == "claude" }) {
            return true
        }
        guard executableBasenames.contains(where: Self.wrapperLooksLikeNodeRuntime) else {
            return false
        }
        return arguments.dropFirst().contains { argument in
            let lowered = argument.lowercased()
            return (argument as NSString).lastPathComponent.lowercased() == "claude"
                || lowered.contains("/.claude/")
                || lowered.contains("/claude/versions/")
        }
    }

    /// True for a real `codex` process: the binary basename is `codex` (the
    /// vendored `…/@openai/codex-darwin-arm64/…/bin/codex`), or a runtime arg
    /// references the codex npm package. A `sr codex` wrapper has argv[0]
    /// basename `sr` and is excluded.
    public var isCodexProcess: Bool {
        if executableBasenames.contains(where: { $0.lowercased() == "codex" }) {
            return true
        }
        return arguments.contains { argument in
            let lowered = argument.lowercased()
            return lowered.contains("@openai/codex") || lowered.contains("codex-darwin-arm64")
        }
    }

    /// The argument that names the opencode executable, when present.
    public var openCodeExecutableArgument: String? {
        guard let index = openCodeExecutableArgumentIndex,
              arguments.indices.contains(index) else {
            return nil
        }
        return arguments[index]
    }

    /// The pi-compatible session identifier parsed from the argument vector.
    public var piCompatibleSessionID: String? {
        AgentResumeArgvParser().piCompatibleSessionID(in: arguments, startingAt: piCompatibleSessionArgumentStartIndex)
    }

    /// The index of the argument that names the opencode executable, peering
    /// through a node/bun runtime wrapper to the node script when needed.
    public var openCodeExecutableArgumentIndex: Int? {
        if let first = arguments.first,
           Self.argumentLooksLikeOpenCode(first) {
            return 0
        }
        guard executableBasenames.contains(where: Self.wrapperLooksLikeNodeRuntime) else {
            return nil
        }
        guard let scriptIndex = Self.nodeScriptArgumentIndex(arguments) else {
            return nil
        }
        return Self.argumentLooksLikeOpenCode(arguments[scriptIndex]) ? scriptIndex : nil
    }

    private var piCompatibleSessionArgumentStartIndex: Int {
        guard !arguments.isEmpty else { return 0 }
        if let scriptIndex = Self.javaScriptRuntimeScriptArgumentIndex(arguments) {
            return min(scriptIndex + 1, arguments.endIndex)
        }
        if arguments[arguments.startIndex].hasPrefix("-") {
            return arguments.startIndex
        }
        return min(arguments.startIndex + 1, arguments.endIndex)
    }

    private var processIdentityLooksLikeOpenCode: Bool {
        executableBasenames.contains { basename in
            let normalized = basename.lowercased()
            return normalized == "opencode" ||
                normalized == ".opencode" ||
                normalized == "opencode-ai" ||
                normalized == "open-code"
        }
    }

    /// True when an argument's basename names the opencode executable.
    public static func argumentLooksLikeOpenCode(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename == "opencode" ||
            basename == ".opencode" ||
            basename == "opencode-ai" ||
            basename == "open-code"
    }

    private static func wrapperLooksLikeJavaScriptRuntime(_ basename: String) -> Bool {
        switch basename.lowercased() {
        case "node", "bun", "deno", "tsx", "ts-node":
            return true
        default:
            return false
        }
    }

    private static func wrapperLooksLikeNodeRuntime(_ basename: String) -> Bool {
        switch basename.lowercased() {
        case "node":
            return true
        default:
            return false
        }
    }

    private static func javaScriptRuntimeScriptArgumentIndex(_ arguments: [String]) -> Int? {
        guard let first = arguments.first else { return nil }
        guard wrapperLooksLikeJavaScriptRuntime((first as NSString).lastPathComponent) else {
            return nil
        }
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let nextIndex = index + 1
                return nextIndex < arguments.count ? nextIndex : nil
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

    private static func nodeScriptArgumentIndex(_ arguments: [String]) -> Int? {
        guard !arguments.isEmpty else { return nil }
        var index = 0
        if wrapperLooksLikeNodeRuntime((arguments[0] as NSString).lastPathComponent) {
            index = 1
        }
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let nextIndex = index + 1
                return nextIndex < arguments.count ? nextIndex : nil
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
             "--conditions", "-C", "--title", "--test-name-pattern",
             "--test-reporter", "--test-reporter-destination":
            return 1
        default:
            return 0
        }
    }
}

extension VaultObservedAgentProcess {
    /// True when every needle is present in the argument vector, matching the
    /// legacy detect-rule semantics: a space-containing needle matches the
    /// space-joined argv, a slash-containing needle matches the NUL-joined argv,
    /// and a plain needle matches any argument or its basename, all
    /// case-insensitively.
    public func argumentsContainAll(_ needles: [String]) -> Bool {
        needles.allSatisfy { needle in
            if needle.contains(" ") {
                let joinedArguments = arguments.joined(separator: " ")
                return joinedArguments.range(of: needle, options: [.caseInsensitive, .literal]) != nil
            }
            if needle.contains("/") {
                let joinedArguments = arguments.joined(separator: "\u{0}")
                return joinedArguments.range(of: needle, options: [.caseInsensitive, .literal]) != nil
            }
            return arguments.contains { argument in
                argument.range(of: needle, options: [.caseInsensitive, .literal]) != nil
                    || (argument as NSString).lastPathComponent.range(
                        of: needle,
                        options: [.caseInsensitive, .literal]
                    ) != nil
            }
        }
    }
}
