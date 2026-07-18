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
        if containsOption(nonSessionOptions(for: kind), in: arguments, policy: policy) {
            return .nonSession
        }
        if kind == "amp", let ampMode = ampMode(arguments: arguments, policy: policy) {
            return ampMode
        }
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
        if kind == "hermes-agent",
           let command = firstPositional(in: arguments, policy: policy),
           command != "chat" {
            return .nonSession
        }
        if kind == "claude",
           containsOption(["--no-session-persistence"], in: arguments, policy: policy) {
            guard containsOption(["--print", "-p"], in: arguments, policy: policy),
                  !containsUnknownOption(in: arguments, policy: policy) else {
                return .unknown
            }
            return .oneShot
        }
        let arguments = normalizedArguments(kind: kind, arguments: arguments)
        let baseCommand = firstPositional(in: arguments, policy: policy)
        if kind == "opencode", baseCommand == "run" {
            policy = AgentLaunchSanitizer.openCodeInteractiveRunPolicy
        } else if kind == "opencode", baseCommand == "attach" {
            // `attach` owns a small option grammar that is not valid on the root
            // TUI. Recognize it only after proving the subcommand so those names
            // cannot make an invalid root launch look replay-safe.
            policy.valueOptions.formUnion([
                "--dir", "--password", "-p", "--username", "-u",
            ])
        } else if kind == "codex", let baseCommand, ["resume", "fork"].contains(baseCommand) {
            // Picker-only selector introduced by Codex 0.144.3. It must be known
            // for lifetime classification but is never meaningful on replay.
            policy.booleanOptions.insert("--include-non-interactive")
            policy.droppedOptions.insert("--include-non-interactive")
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
                return hasUnknownOption ? .unknown : .interactive
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
        let requestsHelp = containsOption(["--help", "-h"], in: arguments, policy: policy)
        let commandLocation = firstPositionalLocation(in: arguments, policy: policy)
        let positionals = positionalValues(in: arguments, policy: policy, limit: 3)
        let command = commandLocation?.value
        switch kind {
        case "amp":
            if containsRawOption(["--no-tui"], in: arguments) {
                return requestsHelp ? .nonSession : .interactive
            }
        case "claude":
            if optionValue("--input-format", in: arguments) == "stream-json" {
                return requestsHelp ? .nonSession : .interactive
            }
        case "pi":
            if optionValue("--mode", in: arguments) == "rpc" {
                return requestsHelp ? .nonSession : .interactive
            }
        case "omp":
            if ["rpc", "rpc-ui"].contains(optionValue("--mode", in: arguments))
                || ["acp", "auth-gateway", "join", "shell"].contains(command) {
                return requestsHelp ? .nonSession : .interactive
            }
        case "campfire":
            if optionValue("--mode", in: arguments) == "rpc" {
                return requestsHelp ? .nonSession : .interactive
            }
        case "factory":
            if command == "exec",
               optionValue("--input-format", in: arguments) == "stream-jsonrpc",
               optionValue("--output-format", in: arguments) == "stream-jsonrpc" {
                return requestsHelp ? .nonSession : .interactive
            }
        case "kimi":
            if containsRawOption(["--acp", "--wire"], in: arguments)
                || ["acp", "term", "web"].contains(command)
                || optionValue("--input-format", in: arguments) == "stream-json" {
                return requestsHelp ? .nonSession : .interactive
            }
        case "hermes-agent":
            if command == "acp" {
                if containsRawOption(
                    ["--check", "--help", "-h", "--setup", "--setup-browser", "--version"],
                    in: arguments
                ) {
                    return .nonSession
                }
                return .interactive
            }
            if command == "gateway" {
                return positionals.dropFirst().first == "run" && !requestsHelp
                    ? .interactive
                    : .nonSession
            }
        case "grok":
            if command == "agent",
               let commandIndex = commandLocation?.index,
               let agentCommand = nestedSubcommand(
                   in: arguments,
                   after: commandIndex,
                   valueOptions: [
                       "--agent-profile", "--cli-chat-proxy-base-url", "--debug-file",
                       "--grok-ws-origin", "--grok-ws-url", "--leader-socket", "--model", "-m",
                       "--plugin-dir", "--reasoning-effort", "--xai-api-base-url",
                   ]
               ),
               ["stdio", "serve", "leader", "headless"].contains(agentCommand) {
                return requestsHelp ? .nonSession : .interactive
            }
        case "opencode":
            if ["acp", "serve", "web"].contains(command) {
                return requestsHelp ? .nonSession : .interactive
            }
        case "codebuddy":
            if containsRawOption(["--acp", "--prewarm", "--serve"], in: arguments) {
                return requestsHelp ? .nonSession : .interactive
            }
        case "rovodev":
            if positionals.starts(with: ["rovodev", "serve"]) || command == "serve" {
                return requestsHelp ? .nonSession : .interactive
            }
        case "qoder":
            if containsRawOption(["--acp"], in: arguments)
                || optionValue("--input-format", in: arguments) == "stream-json" {
                return requestsHelp ? .nonSession : .interactive
            }
        case "codex":
            if command == "app-server" {
                guard !requestsHelp else { return .nonSession }
                let appServerCommand = commandLocation.flatMap {
                    codexAppServerSubcommand(in: arguments, after: $0.index)
                }
                switch appServerCommand {
                case nil, "proxy":
                    return .interactive
                case "daemon", "generate-ts", "generate-json-schema", "help":
                    return .nonSession
                default:
                    return .unknown
                }
            }
            if ["mcp-server", "exec-server"].contains(command) {
                return requestsHelp ? .nonSession : .interactive
            }
            if ["app", "mcp"].contains(command) {
                return .unknown
            }
        default:
            break
        }
        return nil
    }

    /// `app-server` has its own option grammar. Parse its optional nested command without
    /// letting an option value such as `--listen ws://...` masquerade as that command.
    private static func codexAppServerSubcommand(
        in arguments: [String],
        after appServerIndex: Int
    ) -> String? {
        nestedSubcommand(
            in: arguments,
            after: appServerIndex,
            valueOptions: [
                "--config", "-c", "--disable", "--enable", "--listen", "--ws-audience",
                "--ws-auth", "--ws-issuer", "--ws-max-clock-skew-seconds",
                "--ws-shared-secret-file", "--ws-token-file", "--ws-token-sha256",
            ]
        )
    }

    private static func nestedSubcommand(
        in arguments: [String],
        after parentCommandIndex: Int,
        valueOptions: Set<String>
    ) -> String? {
        var index = arguments.index(after: parentCommandIndex)
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--" {
                let next = arguments.index(after: index)
                return next < arguments.endIndex ? arguments[next] : nil
            }
            if argument.hasPrefix("-"), argument != "-" {
                let name = optionName(argument)
                index = arguments.index(after: index)
                if !argument.contains("="), valueOptions.contains(name), index < arguments.endIndex {
                    index = arguments.index(after: index)
                }
                continue
            }
            return argument
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

    /// Amp's nested command aliases overlap (`l` means root `last`, but nested
    /// `threads l` means `list`), so model the documented command grammar before
    /// the generic first-positional classifier. Stream JSON input is a live
    /// multi-turn protocol only when its two required companion flags are present.
    private static func ampMode(
        arguments: [String],
        policy: AgentLaunchSanitizer.Policy
    ) -> AgentProcessLaunchMode? {
        let hasStreamInput = containsRawOption(["--stream-json-input"], in: arguments)
        if hasStreamInput {
            let hasExecute = containsRawOption(["--execute", "-x"], in: arguments)
            let hasStreamOutput = containsRawOption(["--stream-json"], in: arguments)
            return hasExecute && hasStreamOutput ? .interactive : .unknown
        }
        if containsRawOption(["--execute", "-x"], in: arguments) {
            return nil
        }

        let positionals = positionalValues(in: arguments, policy: policy, limit: 3)
        guard let command = positionals.first else { return nil }
        if ["last", "l"].contains(command) {
            return .interactive
        }
        if ["threads", "thread", "t"].contains(command) {
            guard positionals.count >= 2 else { return .nonSession }
            return ["continue", "c"].contains(positionals[1]) ? .interactive : .nonSession
        }
        return AgentLaunchSanitizer.ampPolicy.nonRestorableCommands.contains(command)
            ? .nonSession
            : nil
    }

    private static func policy(for kind: String) -> AgentLaunchSanitizer.Policy? {
        switch kind {
        case "claude": AgentLaunchSanitizer.claudePolicy
        case "codex": AgentLaunchSanitizer.codexPolicy
        case "grok": AgentLaunchSanitizer.grokPolicy
        case "pi": AgentLaunchSanitizer.piPolicy
        case "omp": AgentLaunchSanitizer.ompPolicy
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
        case "qoder": ["--print", "-p", "--remote"]
        case "kimi": ["--print", "--quiet"]
        default: []
        }
    }

    private static func interactiveOptions(for kind: String) -> Set<String> {
        switch kind {
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
        case "claude": ["ultrareview"]
        case "codex": ["exec", "e", "review"]
        case "opencode": ["run"]
        case "factory": ["exec"]
        default: []
        }
    }

    private static func nonSessionOptions(for kind: String) -> Set<String> {
        var options = AgentLaunchSanitizer.nonSessionMetadataOptions(kind: kind)
        switch kind {
        case "gemini":
            options.formUnion(["--list-sessions", "--delete-session", "--list-extensions"])
        case "pi", "campfire":
            options.formUnion(["--export", "--list-models"])
        case "omp":
            options.formUnion(["--alias", "--export", "--list-models"])
        case "cursor":
            options.insert("--list-models")
        case "factory":
            options.insert("--list-tools")
        case "kiro":
            options.formUnion(["--delete-session", "--list-models", "--list-sessions"])
        case "codebuddy":
            options.formUnion(["--background", "--bg"])
        case "qoder":
            options.formUnion(["--delete-session", "--list-sessions"])
        default:
            break
        }
        return options
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
