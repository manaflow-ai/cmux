import Foundation

struct VaultObservedAgentProcess: Sendable {
    let processName: String
    let processPath: String?
    let arguments: [String]
    let environment: [String: String]

    init(
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

    var executableBasenames: [String] {
        var names: [String] = []
        if !processName.isEmpty { names.append(processName) }
        if let processPath, !processPath.isEmpty { names.append((processPath as NSString).lastPathComponent) }
        if let first = arguments.first, !first.isEmpty { names.append((first as NSString).lastPathComponent) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    var isOpenCodeProcess: Bool {
        processIdentityLooksLikeOpenCode || openCodeExecutableArgumentIndex != nil
    }

    var openCodeExecutableArgument: String? {
        guard let index = openCodeExecutableArgumentIndex,
              arguments.indices.contains(index) else {
            return nil
        }
        return arguments[index]
    }

    var piCompatibleSessionID: String? {
        arguments.piCompatibleSessionID(startingAt: piCompatibleSessionArgumentStartIndex)
    }

    /// Whether this Hermes process owns an interactive conversation that cmux can restore.
    ///
    /// The installed launcher execs Python with `hermes-agent/hermes` as its script, so the
    /// first Hermes argument is not always at index one. Management subcommands such as
    /// `gateway`, `doctor`, and `update`, plus one-shot query modes, must not become resumable
    /// chat panes.
    var isInteractiveHermesAgentInvocation: Bool {
        var index = hermesAgentArgumentStartIndex
        var commandIndex: Int?
        while index < arguments.endIndex {
            let argument = arguments[index]
            if Self.isHermesOneShotOption(argument) {
                return false
            }
            if argument == "--" {
                let nextIndex = arguments.index(after: index)
                commandIndex = nextIndex < arguments.endIndex ? nextIndex : nil
                break
            }
            guard argument.hasPrefix("-") else {
                commandIndex = index
                break
            }

            let option = argument
                .split(separator: "=", maxSplits: 1)
                .first
                .map(String.init) ?? argument
            if !argument.contains("="), Self.hermesTopLevelOptionConsumesValue(option) {
                index = min(index + 2, arguments.endIndex)
            } else {
                index += 1
            }
        }

        guard let commandIndex else { return true }
        let command = arguments[commandIndex]
        guard command.compare("chat", options: [.caseInsensitive, .literal]) == .orderedSame else {
            return false
        }
        return !arguments[arguments.index(after: commandIndex)...].contains { argument in
            Self.isHermesChatQueryOption(argument)
        }
    }

    var openCodeExecutableArgumentIndex: Int? {
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

    private var hermesAgentArgumentStartIndex: Int {
        if let entrypointIndex = arguments.indices.first(where: {
            Self.argumentLooksLikeHermesAgentEntrypoint(arguments[$0])
        }) {
            return arguments.index(after: entrypointIndex)
        }
        return arguments.isEmpty
            ? arguments.startIndex
            : arguments.index(after: arguments.startIndex)
    }

    private static func argumentLooksLikeHermesAgentEntrypoint(_ argument: String) -> Bool {
        let normalized = argument.replacingOccurrences(of: "\\", with: "/")
        let basename = (normalized as NSString).lastPathComponent
        if basename.compare("hermes", options: [.caseInsensitive, .literal]) == .orderedSame
            || basename.compare("hermes-agent", options: [.caseInsensitive, .literal]) == .orderedSame {
            return true
        }
        return normalized.range(
            of: "hermes-agent/hermes",
            options: [.caseInsensitive, .literal]
        ) != nil
    }

    private static func hermesTopLevelOptionConsumesValue(_ option: String) -> Bool {
        switch option {
        case "-z", "--oneshot", "-m", "--model", "--provider", "--reasoning",
             "-t", "--toolsets", "-r", "--resume", "-c", "--continue",
             "-s", "--skills", "--usage-file", "-p", "--profile":
            return true
        default:
            return false
        }
    }

    private static func isHermesOneShotOption(_ argument: String) -> Bool {
        argument == "-z"
            || argument.hasPrefix("-z")
            || argument == "--oneshot"
            || argument.hasPrefix("--oneshot=")
    }

    private static func isHermesChatQueryOption(_ argument: String) -> Bool {
        argument == "-q"
            || argument.hasPrefix("-q")
            || argument == "--query"
            || argument.hasPrefix("--query=")
    }

    static func argumentLooksLikeOpenCode(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename == "opencode" ||
            basename == ".opencode" ||
            basename == "opencode-ai" ||
            basename == "open-code"
    }

    static func argumentLooksLikeTmux(_ argument: String) -> Bool {
        TmuxResumeParser.argumentLooksLikeTmux(argument)
    }

    static func argumentLooksLikeTmuxProcessTitle(_ argument: String) -> Bool {
        TmuxResumeParser.argumentLooksLikeTmuxProcessTitle(argument)
    }

    static func argumentLooksLikeTmuxServerProcessTitle(_ argument: String) -> Bool {
        TmuxResumeParser.argumentLooksLikeTmuxServerProcessTitle(argument)
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
    func argumentsContainAll(_ needles: [String]) -> Bool {
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

extension Array where Element == String {
    func piCompatibleSessionID(startingAt startIndex: Int) -> String? {
        guard startIndex < endIndex else { return nil }
        for index in indices where index >= startIndex {
            let argument = self[index]
            if argument == "--session" || argument == "--resume" || argument == "-r" {
                let nextIndex = self.index(after: index)
                guard nextIndex < endIndex else { continue }
                if let value = normalizedNonOptionValue(self[nextIndex]) {
                    return value
                }
                continue
            }
            if argument.hasPrefix("--session="),
               let value = normalizedNonOptionValue(String(argument.dropFirst("--session=".count))) {
                return value
            }
            if argument.hasPrefix("--resume="),
               let value = normalizedNonOptionValue(String(argument.dropFirst("--resume=".count))) {
                return value
            }
            if argument.hasPrefix("-r="),
               let value = normalizedNonOptionValue(String(argument.dropFirst("-r=".count))) {
                return value
            }
        }
        return nil
    }

    private func normalizedNonOptionValue(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !value.hasPrefix("-") ? value : nil
    }
}
