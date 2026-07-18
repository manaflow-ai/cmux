import Foundation

/// Whether a provider process is expected to remain alive after a turn event.
/// This is independent from replay safety: an interactive launch can be
/// intentionally non-restorable and must still retain live session authority.
public enum AgentProcessLaunchMode: Sendable, Equatable {
    case interactive
    case oneShot
    case nonSession
    case unknown
}

public enum AgentLaunchModeClassifier {
    public static func processMode(
        processName: String?,
        arguments: [String]?,
        kind: String
    ) -> AgentProcessLaunchMode {
        guard let arguments,
              let providerArguments = AgentLaunchCaptureTrust.nativeAgentLaunchArguments(
                  processName: processName,
                  arguments: arguments,
                  kind: kind
              ) else {
            return .unknown
        }
        return mode(kind: kind, arguments: providerArguments)
    }

    static func mode(kind: String, arguments: [String]) -> AgentProcessLaunchMode {
        let kind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard var policy = policy(for: kind) else { return .unknown }
        if let protocolMode = longLivedProtocolMode(kind: kind, arguments: arguments, policy: policy) {
            return protocolMode
        }
        if kind == "rovodev" {
            return rovoDevMode(arguments: arguments, policy: policy)
        }
        if kind == "kiro",
           containsOption(["--no-interactive"], in: arguments, policy: policy) {
            guard firstPositional(in: arguments, policy: policy) == "chat",
                  !containsUnknownOption(in: arguments, policy: policy) else {
                return .unknown
            }
            return .oneShot
        }
        if kind == "hermes-agent", arguments.first == "chat",
           containsOption(["--query", "-q"], in: Array(arguments.dropFirst()), policy: policy) {
            return .oneShot
        }
        let arguments = normalizedArguments(kind: kind, arguments: arguments)
        if kind == "opencode",
           containsRawOption(interactiveOptions(for: kind), in: arguments) {
            guard firstPositional(in: arguments, policy: policy) == "run" else {
                return .unknown
            }
            policy = AgentLaunchSanitizer.openCodeInteractiveRunPolicy
        }
        let hasOneShotOption = containsOption(oneShotOptions(for: kind), in: arguments, policy: policy)
        let hasInteractiveOption = containsOption(interactiveOptions(for: kind), in: arguments, policy: policy)
        let hasExplicitUnknownOption = containsOption(unknownOptions(for: kind), in: arguments, policy: policy)
        let hasUnknownOption = containsUnknownOption(in: arguments, policy: policy)
        if hasOneShotOption && (hasInteractiveOption || hasExplicitUnknownOption) {
            return .unknown
        }
        if hasInteractiveOption {
            return hasUnknownOption ? .unknown : .interactive
        }
        if hasExplicitUnknownOption {
            return .unknown
        }
        if hasOneShotOption {
            return hasUnknownOption ? .unknown : .oneShot
        }

        let commandLocation = firstPositionalLocation(in: arguments, policy: policy)
        let command = commandLocation?.value
        if let command {
            if oneShotCommands(for: kind).contains(command) {
                if let commandIndex = commandLocation?.index,
                   containsUnknownOption(
                       in: Array(arguments.prefix(upTo: commandIndex)),
                       policy: policy
                ) {
                    return .unknown
                }
                if !oneShotCommandAllowsUnknownTrailingOptions(kind: kind, command: command),
                   containsUnknownOption(in: arguments, policy: policy) {
                    return .unknown
                }
                return .oneShot
            }
            if interactiveCommands(for: kind).contains(command) {
                return .interactive
            }
        }
        if hasUnknownOption {
            return .unknown
        }
        if let command, policy.nonRestorableCommands.contains(command) {
            return .nonSession
        }
        return .interactive
    }

    /// Protocol and service modes own a live process across multiple turns.
    /// They take precedence over terminal-looking flags so malformed or mixed
    /// argv can never retire a server at its first Stop event.
    private static func longLivedProtocolMode(
        kind: String,
        arguments: [String],
        policy: AgentLaunchSanitizer.Policy
    ) -> AgentProcessLaunchMode? {
        let positionals = positionalValues(in: arguments, policy: policy, limit: 3)
        let command = positionals.first
        switch kind {
        case "claude":
            if optionValue("--input-format", in: arguments) == "stream-json" {
                return .interactive
            }
        case "pi":
            if optionValue("--mode", in: arguments) == "rpc" {
                return .interactive
            }
        case "omp":
            if ["rpc", "rpc-ui"].contains(optionValue("--mode", in: arguments)) || command == "acp" {
                return .interactive
            }
        case "campfire":
            if optionValue("--mode", in: arguments) == "rpc" {
                return .interactive
            }
        case "factory":
            if command == "exec",
               optionValue("--input-format", in: arguments) == "stream-jsonrpc",
               optionValue("--output-format", in: arguments) == "stream-jsonrpc" {
                return .interactive
            }
        case "kimi":
            if containsRawOption(["--acp", "--wire"], in: arguments)
                || ["acp", "term", "web"].contains(command)
                || optionValue("--input-format", in: arguments) == "stream-json" {
                return .interactive
            }
        case "hermes-agent":
            if ["acp", "gateway"].contains(command) {
                return .interactive
            }
        case "grok":
            if positionals.first == "agent",
               positionals.count > 1,
               ["stdio", "serve", "leader", "headless"].contains(positionals[1]) {
                return .interactive
            }
        case "opencode":
            if ["acp", "serve", "web"].contains(command) {
                return .interactive
            }
        case "qoder":
            if containsRawOption(["--acp"], in: arguments)
                || optionValue("--input-format", in: arguments) == "stream-json" {
                return .interactive
            }
        case "codex":
            if ["app-server", "mcp-server", "exec-server"].contains(command) {
                return .interactive
            }
            if ["app", "mcp"].contains(command) {
                return .unknown
            }
        default:
            break
        }
        return nil
    }

    private static func rovoDevMode(
        arguments: [String],
        policy: AgentLaunchSanitizer.Policy
    ) -> AgentProcessLaunchMode {
        let runArguments: [String]
        if arguments.starts(with: ["rovodev", "run"]) {
            runArguments = Array(arguments.dropFirst(2))
        } else if arguments.first == "run" {
            runArguments = Array(arguments.dropFirst())
        } else if arguments.isEmpty {
            return .interactive
        } else {
            return .unknown
        }
        let hasInteractiveOption = containsOption(
            interactiveOptions(for: "rovodev"),
            in: runArguments,
            policy: policy
        )
        let hasOneShotOption = containsOption(
            oneShotOptions(for: "rovodev"),
            in: runArguments,
            policy: policy
        )
        let hasUnknownOption = containsOption(
            unknownOptions(for: "rovodev"),
            in: runArguments,
            policy: policy
        ) || containsUnknownOption(in: runArguments, policy: policy)
        if hasUnknownOption || (hasInteractiveOption && hasOneShotOption) {
            return .unknown
        }
        if hasInteractiveOption { return .interactive }
        if hasOneShotOption {
            return .oneShot
        }
        return firstPositional(in: runArguments, policy: policy) == nil ? .interactive : .oneShot
    }

    private static func policy(for kind: String) -> AgentLaunchSanitizer.Policy? {
        switch kind {
        case "claude": AgentLaunchSanitizer.claudePolicy
        case "codex": AgentLaunchSanitizer.codexPolicy
        case "grok": AgentLaunchSanitizer.grokPolicy
        case "pi", "omp": AgentLaunchSanitizer.piPolicy
        case "campfire": AgentLaunchSanitizer.campfirePolicy
        case "amp": AgentLaunchSanitizer.ampPolicy
        case "gemini": AgentLaunchSanitizer.geminiPolicy
        case "antigravity": AgentLaunchSanitizer.antigravityPolicy
        case "cursor": AgentLaunchSanitizer.cursorPolicy
        case "opencode": AgentLaunchSanitizer.openCodePolicy
        case "rovodev": AgentLaunchSanitizer.rovoDevPolicy
        case "hermes-agent": AgentLaunchSanitizer.hermesAgentPolicy
        case "copilot": AgentLaunchSanitizer.copilotPolicy
        case "codebuddy": AgentLaunchSanitizer.codeBuddyPolicy
        case "factory": AgentLaunchSanitizer.factoryPolicy
        case "qoder": AgentLaunchSanitizer.qoderPolicy
        case "kiro": AgentLaunchSanitizer.kiroPolicy
        case "kimi": AgentLaunchSanitizer.kimiPolicy
        default: nil
        }
    }

    private static func oneShotOptions(for kind: String) -> Set<String> {
        switch kind {
        case "claude": ["--print", "-p"]
        case "grok": ["--single", "-p", "--prompt-file", "--prompt-json"]
        case "pi", "omp", "campfire": ["--print", "-p"]
        case "amp": ["--execute", "--print", "-x"]
        case "gemini": ["--prompt", "-p"]
        case "antigravity": ["--prompt", "-p", "--print"]
        case "cursor": ["--print", "-p"]
        case "rovodev": ["--prompt", "-p", "--print"]
        case "hermes-agent": ["--oneshot", "-z"]
        case "copilot": ["--prompt", "-p"]
        case "codebuddy": ["--print", "-p"]
        case "qoder": ["--print", "-p"]
        case "kimi": ["--print", "--quiet"]
        default: []
        }
    }

    private static func interactiveOptions(for kind: String) -> Set<String> {
        switch kind {
        case "claude": ["--no-session-persistence"]
        case "pi", "omp", "campfire": ["--no-session"]
        case "gemini", "antigravity", "rovodev", "qoder": ["--prompt-interactive", "-i"]
        case "kimi": ["--prompt", "--command", "-p", "-c"]
        case "opencode": ["--interactive", "-i"]
        default: []
        }
    }

    private static func unknownOptions(for kind: String) -> Set<String> {
        switch kind {
        case "claude": ["--background", "--bg"]
        case "pi", "omp": ["--prompt"]
        case "campfire": ["--prompt"]
        case "hermes-agent": ["--query", "-q"]
        case "kiro": ["--no-interactive"]
        default: []
        }
    }

    private static func oneShotCommands(for kind: String) -> Set<String> {
        switch kind {
        case "codex": ["exec", "e", "review"]
        case "opencode": ["run"]
        case "factory": ["exec"]
        default: []
        }
    }

    private static func oneShotCommandAllowsUnknownTrailingOptions(
        kind: String,
        command: String
    ) -> Bool {
        kind == "codex" && ["exec", "e", "review"].contains(command)
    }

    private static func interactiveCommands(for kind: String) -> Set<String> {
        switch kind {
        case "codex": ["resume", "fork"]
        case "opencode": ["attach", "pr"]
        case "kiro": ["chat"]
        default: []
        }
    }

    private static func normalizedArguments(kind: String, arguments: [String]) -> [String] {
        var arguments = arguments
        if kind == "cursor", arguments.first == "agent" {
            arguments.removeFirst()
        }
        if kind == "rovodev", arguments.first == "rovodev" {
            arguments.removeFirst()
            if arguments.first == "run" { arguments.removeFirst() }
        }
        if kind == "hermes-agent", arguments.first == "chat" {
            arguments.removeFirst()
        }
        return arguments
    }

    private static func containsOption(
        _ options: Set<String>,
        in arguments: [String],
        policy: AgentLaunchSanitizer.Policy
    ) -> Bool {
        guard !options.isEmpty else { return false }
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return false }
            if argument.hasPrefix("-"), argument != "-" {
                let name = optionName(argument)
                if options.contains(name) { return true }
                index += max(1, AgentLaunchSanitizer.optionWidth(arguments, index: index, policy: policy))
            } else {
                index += 1
            }
        }
        return false
    }

    private static func containsUnknownOption(
        in arguments: [String],
        policy: AgentLaunchSanitizer.Policy
    ) -> Bool {
        let knownOptions = policy.valueOptions
            .union(policy.optionalValueOptions)
            .union(policy.booleanOptions)
            .union(policy.droppedOptions)
            .union(policy.rejectOptions)
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return false }
            guard argument.hasPrefix("-"), argument != "-" else {
                index += 1
                continue
            }
            let name = optionName(argument)
            let knownPrefix = policy.droppedOptionPrefixes.contains(where: argument.hasPrefix)
            if !knownOptions.contains(name), !knownPrefix {
                return true
            }
            index += max(1, AgentLaunchSanitizer.optionWidth(arguments, index: index, policy: policy))
        }
        return false
    }

    private static func firstPositional(
        in arguments: [String],
        policy: AgentLaunchSanitizer.Policy
    ) -> String? {
        firstPositionalLocation(in: arguments, policy: policy)?.value
    }

    private static func firstPositionalLocation(
        in arguments: [String],
        policy: AgentLaunchSanitizer.Policy
    ) -> (index: Int, value: String)? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return nil }
            if argument.hasPrefix("-"), argument != "-" {
                index += max(1, AgentLaunchSanitizer.optionWidth(arguments, index: index, policy: policy))
                continue
            }
            return (index, argument)
        }
        return nil
    }

    private static func positionalValues(
        in arguments: [String],
        policy: AgentLaunchSanitizer.Policy,
        limit: Int
    ) -> [String] {
        var values: [String] = []
        var index = 0
        while index < arguments.count, values.count < limit {
            let argument = arguments[index]
            if argument == "--" { break }
            if argument.hasPrefix("-"), argument != "-" {
                index += max(1, AgentLaunchSanitizer.optionWidth(arguments, index: index, policy: policy))
            } else {
                values.append(argument)
                index += 1
            }
        }
        return values
    }

    private static func optionValue(_ option: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == option, index + 1 < arguments.count {
                return arguments[index + 1].lowercased()
            }
            if argument.hasPrefix("\(option)=") {
                return String(argument.dropFirst(option.count + 1)).lowercased()
            }
        }
        return nil
    }

    private static func containsRawOption(_ options: Set<String>, in arguments: [String]) -> Bool {
        arguments.contains { options.contains(optionName($0)) }
    }

    private static func optionName(_ argument: String) -> String {
        guard let equals = argument.firstIndex(of: "=") else { return argument }
        return String(argument[..<equals])
    }
}
