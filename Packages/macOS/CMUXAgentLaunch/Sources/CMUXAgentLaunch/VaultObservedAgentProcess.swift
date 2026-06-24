public import Foundation

/// A process observed by the agent-process scanner, reduced to the argv/identity
/// signal needed to decide which coding agent (if any) it is running.
///
/// Carries the process name, executable path, argument vector, and environment,
/// and derives agent identity purely from those: whether the executable basename
/// is `claude`/`codex`/`opencode`, or whether a JavaScript runtime (`node`) is
/// running one of those tools' scripts. The detection mirrors the live-PID matcher
/// `liveProcessExecutableMatchesRecordedAgent` and deliberately excludes shell
/// wrappers (`sr claude`, `sh -c …`) whose argv[0] basename is the wrapper, not
/// the agent.
///
/// This type owns only the process-independent argv/identity math. The pieces that
/// need a `CmuxVaultAgentRegistration` or the session index stay app-side and read
/// these members (it is `public` so they can).
public struct VaultObservedAgentProcess: Sendable {
    public let processName: String
    public let processPath: String?
    public let arguments: [String]
    public let environment: [String: String]

    /// Creates an observed process from its raw scanner fields.
    ///
    /// - Parameters:
    ///   - processName: The kernel-reported process name (`comm`).
    ///   - processPath: The absolute executable path, when known.
    ///   - arguments: The full argument vector, argv[0] first.
    ///   - environment: The process environment.
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

    /// The distinct executable basenames worth matching against: the process name,
    /// the last path component of the executable path, and the last path component
    /// of argv[0], in that order, de-duplicated while preserving first appearance.
    public var executableBasenames: [String] {
        var names: [String] = []
        if !processName.isEmpty { names.append(processName) }
        if let processPath, !processPath.isEmpty { names.append((processPath as NSString).lastPathComponent) }
        if let first = arguments.first, !first.isEmpty { names.append((first as NSString).lastPathComponent) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// True when this process is an OpenCode process, by executable identity or by
    /// a node runtime running an OpenCode script (see `openCodeExecutableArgumentIndex`).
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

    /// The argv element that names the OpenCode executable/script, or `nil` when
    /// this is not an OpenCode process.
    public var openCodeExecutableArgument: String? {
        guard let index = openCodeExecutableArgumentIndex,
              arguments.indices.contains(index) else {
            return nil
        }
        return arguments[index]
    }

    /// The `pi`-compatible session id parsed from argv, starting after the
    /// JavaScript runtime's script argument (or after argv[0] for a direct binary).
    public var piCompatibleSessionID: String? {
        arguments.piCompatibleSessionID(startingAt: piCompatibleSessionArgumentStartIndex)
    }

    /// The argv index naming the OpenCode executable/script: argv[0] when it is the
    /// OpenCode binary, or the node script argument when a node runtime runs an
    /// OpenCode script. `nil` when this is not an OpenCode process.
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

    /// True when `argument`'s basename names the OpenCode executable/script.
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
    /// True when every needle matches argv, with three matching modes:
    /// a needle containing a space matches against the space-joined argv; a needle
    /// containing `/` matches against the NUL-joined argv (so a path fragment can
    /// span adjacent argv elements); otherwise the needle matches any single argv
    /// element or its basename. All matches are case-insensitive and literal.
    ///
    /// - Parameter needles: The substrings that must all be present in argv.
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
