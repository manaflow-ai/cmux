/// Classifies managed-launcher arguments without starting a provider session.
///
/// The classifier is an instance value so the launch/non-launch policy has one
/// explicit owner instead of accumulating namespace helpers on
/// ``AgentLaunchSanitizer``.
public struct AgentLaunchInvocationClassifier {
    private let claudeTeamsManagementCommands: Set<String>
    private let claudeTeamsManagementSubcommands: [String: Set<String>]
    private let informationalOptions: Set<String>
    private let omxManagementCommands: Set<String>
    private let claudeTeamsManagementDisqualifyingOptions: Set<String>

    /// Creates a classifier with the supported providers' documented command policies.
    public init() {
        claudeTeamsManagementCommands = [
            "auth",
            "auto-mode",
            "doctor",
            "gateway",
            "install",
            "kill",
            "logs",
            "mcp",
            "plugin",
            "plugins",
            "project",
            "rm",
            "setup-token",
            "stop",
            "update",
            "upgrade",
        ]
        claudeTeamsManagementSubcommands = [
            "daemon": ["logs", "status", "stop", "uninstall"],
        ]
        informationalOptions = ["--help", "-h", "--version", "-v", "-V"]
        omxManagementCommands = [
            "ask",
            "agents",
            "agents-init",
            "auth",
            "cancel",
            "capabilities",
            "deepinit",
            "doctor",
            "explore",
            "help",
            "hooks",
            "hud",
            "list",
            "reasoning",
            "session",
            "setup",
            "sparkshell",
            "status",
            "tmux-hook",
            "uninstall",
            "update",
            "version",
        ]
        claudeTeamsManagementDisqualifyingOptions = [
            "--background",
            "--bg",
            "--continue",
            "-c",
            "--fork-session",
            "--from-pr",
            "--no-session-persistence",
            "--print",
            "-p",
            "--remote-control",
            "--resume",
            "-r",
            "--session-id",
            "--worktree",
            "-w",
        ]
    }

    /// Whether `args` select one of Claude's administrative commands instead of
    /// launching or resuming an agent session.
    ///
    /// Parsing follows the Claude Teams prompt boundary. Unknown options,
    /// session-routing options, option values, `--tmux` prompt payloads, `--`, and
    /// ordinary prompts all fail closed so command-shaped user text cannot bypass
    /// managed-surface validation.
    public func claudeTeamsLaunchIsManagementCommand(args: [String]) -> Bool {
        let policy = AgentLaunchSanitizer.claudeTeamsPolicy
        var index = 0
        var sink: [String] = []
        while index < args.count {
            let argument = args[index]
            if argument == "--" { return false }
            if !argument.hasPrefix("-") || argument == "-" {
                if argument == "agents" {
                    return claudeTeamsAgentsJSONInvocation(
                        args: args,
                        startIndex: index + 1
                    )
                }
                if let allowedSubcommands = claudeTeamsManagementSubcommands[argument] {
                    return claudeTeamsManagementSubcommand(
                        args: args,
                        startIndex: index + 1,
                        allowedSubcommands: allowedSubcommands
                    )
                }
                return claudeTeamsManagementCommands.contains(argument)
            }
            let name = optionName(argument)
            guard claudeTeamsPolicyRecognizesOption(argument, policy: policy),
                  !claudeTeamsManagementDisqualifyingOptions.contains(name) else {
                return false
            }
            if (name == "--debug" || name == "-d"), !argument.contains("=") {
                // Claude may consume the next token as an optional debug filter,
                // so an unattached value makes the command boundary ambiguous.
                return false
            }
            let width = AgentLaunchSanitizer.optionWidth(args, index: index, policy: policy)
            guard let consumedBoundary = AgentLaunchSanitizer.consumePromptBoundaryOption(
                argument,
                args: args,
                index: &index,
                width: width,
                policy: policy,
                result: &sink
            ) else {
                return false
            }
            if consumedBoundary { continue }
            index += max(width, 1)
        }
        return false
    }

    /// Whether Codex arguments select help or version output instead of launching a session.
    ///
    /// Codex accepts these flags after subcommands and positional arguments. The explicit `--`
    /// delimiter is the only boundary after which a flag-shaped token belongs to provider input.
    public func codexTeamsLaunchIsInformational(args: [String]) -> Bool {
        if args.first == "help" { return true }
        for argument in args {
            if argument == "--" { return false }
            switch argument {
            case "--help", "-h", "--version", "-V":
                return true
            default:
                continue
            }
        }
        return false
    }

    private func claudeTeamsAgentsJSONInvocation(args: [String], startIndex: Int) -> Bool {
        var sawJSON = false
        for argument in args.dropFirst(startIndex) {
            switch argument {
            case "--json":
                guard !sawJSON else { return false }
                sawJSON = true
            case "--all":
                continue
            default:
                return false
            }
        }
        return sawJSON
    }

    private func claudeTeamsManagementSubcommand(
        args: [String],
        startIndex: Int,
        allowedSubcommands: Set<String>
    ) -> Bool {
        var index = startIndex
        while index < args.count {
            let argument = args[index]
            if argument == "--" { return false }
            if !argument.hasPrefix("-") || argument == "-" {
                return allowedSubcommands.contains(argument)
            }
            let name = optionName(argument)
            guard name == "--json-path" || name == "--log-file" else { return false }
            if argument.contains("=") {
                index += 1
            } else {
                guard index + 1 < args.count else { return false }
                index += 2
            }
        }
        return false
    }

    /// Whether OpenCode arguments select help, version, or a command that cannot host sessions.
    public func omoLaunchIsNonLaunch(args: [String]) -> Bool {
        conservativeNonLaunchInvocation(
            args: args,
            managementCommands: [
                "agent",
                "auth",
                "completion",
                "db",
                "debug",
                "export",
                "import",
                "mcp",
                "models",
                "plugin",
                "plug",
                "providers",
                "stats",
                "uninstall",
                "upgrade",
            ],
            managementSubcommands: [
                "github": ["install"],
                "session": ["delete", "list"],
            ],
            booleanOptions: ["--mdns", "--print-logs", "--pure"],
            valueOptions: ["--cors", "--hostname", "--log-level", "--mdns-domain", "--port"]
        )
    }

    /// Whether OMC arguments select configuration, diagnostics, or another
    /// command that does not start an agent or team session.
    public func omcLaunchIsNonLaunch(args: [String]) -> Bool {
        conservativeNonLaunchInvocation(
            args: args,
            managementCommands: [
                "ask",
                "capabilities",
                "config",
                "config-notify-profile",
                "config-stop-callback",
                "doctor",
                "help",
                "info",
                "install",
                "postinstall",
                "session",
                "setup",
                "teleport",
                "test-prompt",
                "update",
                "update-reconcile",
                "version",
            ],
            managementSubcommands: [
                "team": ["--help", "-h", "api", "shutdown", "status"],
            ],
            booleanOptions: [],
            valueOptions: []
        )
    }

    /// Whether OMX arguments select help, version, or a documented management command.
    public func omxLaunchIsNonLaunch(args: [String]) -> Bool {
        guard let first = args.first else { return false }
        if informationalOptions.contains(first) { return true }
        if !first.hasPrefix("-") || first == "-" {
            if nestedInformationalInvocation(
                args: args,
                startIndex: 1,
                booleanOptions: [],
                valueOptions: []
            ) {
                return true
            }
        }
        if first == "team" {
            guard args.count > 1 else { return false }
            switch args[1] {
            case "--help", "-h", "api", "shutdown", "status":
                return true
            default:
                return false
            }
        }
        return omxManagementCommands.contains(first)
    }

    private func conservativeNonLaunchInvocation(
        args: [String],
        managementCommands: Set<String>,
        managementSubcommands: [String: Set<String>] = [:],
        booleanOptions: Set<String>,
        valueOptions: Set<String>
    ) -> Bool {
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" { return false }
            if !argument.hasPrefix("-") || argument == "-" {
                if nestedInformationalInvocation(
                    args: args,
                    startIndex: index + 1,
                    booleanOptions: booleanOptions,
                    valueOptions: valueOptions
                ) {
                    return true
                }
                if let allowedSubcommands = managementSubcommands[argument] {
                    return managementSubcommandInvocation(
                        args: args,
                        startIndex: index + 1,
                        allowedSubcommands: allowedSubcommands,
                        booleanOptions: booleanOptions,
                        valueOptions: valueOptions
                    )
                }
                return managementCommands.contains(argument)
            }
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if informationalOptions.contains(option) { return true }
            guard let nextIndex = indexAfterRecognizedOption(
                args: args,
                index: index,
                booleanOptions: booleanOptions,
                valueOptions: valueOptions
            ) else { return false }
            index = nextIndex
        }
        return false
    }

    private func managementSubcommandInvocation(
        args: [String],
        startIndex: Int,
        allowedSubcommands: Set<String>,
        booleanOptions: Set<String>,
        valueOptions: Set<String>
    ) -> Bool {
        var index = startIndex
        while index < args.count {
            let argument = args[index]
            if argument == "--" { return false }
            if !argument.hasPrefix("-") || argument == "-" {
                return allowedSubcommands.contains(argument)
            }
            guard let nextIndex = indexAfterRecognizedOption(
                args: args,
                index: index,
                booleanOptions: booleanOptions,
                valueOptions: valueOptions
            ) else { return false }
            index = nextIndex
        }
        return false
    }

    private func nestedInformationalInvocation(
        args: [String],
        startIndex: Int,
        booleanOptions: Set<String>,
        valueOptions: Set<String>
    ) -> Bool {
        var index = startIndex
        while index < args.count {
            let argument = args[index]
            if argument == "--" { return false }
            if !argument.hasPrefix("-") || argument == "-" {
                index += 1
                continue
            }
            let option = optionName(argument)
            if informationalOptions.contains(option) { return true }
            guard let nextIndex = indexAfterRecognizedOption(
                args: args,
                index: index,
                booleanOptions: booleanOptions,
                valueOptions: valueOptions
            ) else { return false }
            index = nextIndex
        }
        return false
    }

    private func indexAfterRecognizedOption(
        args: [String],
        index: Int,
        booleanOptions: Set<String>,
        valueOptions: Set<String>
    ) -> Int? {
        let argument = args[index]
        let option = optionName(argument)
        if booleanOptions.contains(option) { return index + 1 }
        guard valueOptions.contains(option) else { return nil }
        if argument.contains("=") { return index + 1 }
        guard index + 1 < args.count else { return nil }
        return index + 2
    }

    private func claudeTeamsPolicyRecognizesOption(
        _ argument: String,
        policy: AgentLaunchSanitizer.Policy
    ) -> Bool {
        let name = optionName(argument)
        return policy.valueOptions.contains(name)
            || policy.optionalValueOptions.contains(name)
            || policy.booleanOptions.contains(name)
            || policy.variadicOptions.contains(name)
            || policy.droppedOptions.contains(name)
            || policy.rejectOptions.contains(name)
            || policy.promptBoundaryOptions.contains(name)
            || policy.droppedOptionPrefixes.contains(where: { argument.hasPrefix($0) })
            || AgentLaunchSanitizer.runtimeOnlyOptionWidth(argument) != nil
    }

    private func optionName(_ argument: String) -> String {
        guard let equals = argument.firstIndex(of: "=") else { return argument }
        return String(argument[..<equals])
    }
}
