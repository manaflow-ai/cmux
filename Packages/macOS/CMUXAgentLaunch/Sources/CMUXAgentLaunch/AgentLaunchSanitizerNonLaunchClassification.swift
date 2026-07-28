extension AgentLaunchSanitizer {
    /// Whether `args` select one of Claude's administrative commands instead of
    /// launching or resuming an agent session.
    ///
    /// Parsing follows the Claude Teams prompt boundary. Unknown options,
    /// session-routing options, option values, `--tmux` prompt payloads, `--`, and
    /// ordinary prompts all fail closed so command-shaped user text cannot bypass
    /// managed-surface validation.
    public static func claudeTeamsLaunchIsManagementCommand(args: [String]) -> Bool {
        let policy = claudeTeamsPolicy
        var index = 0
        var sink: [String] = []
        while index < args.count {
            let argument = args[index]
            if argument == "--" { return false }
            if !argument.hasPrefix("-") || argument == "-" {
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
            let width = optionWidth(args, index: index, policy: policy)
            guard let consumedBoundary = consumePromptBoundaryOption(
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

    /// Whether OpenCode arguments select help, version, or a command that cannot host sessions.
    public static func omoLaunchIsNonLaunch(args: [String]) -> Bool {
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
                "session": ["delete", "list"],
            ],
            booleanOptions: ["--mdns", "--print-logs", "--pure"],
            valueOptions: ["--cors", "--hostname", "--log-level", "--mdns-domain", "--port"]
        )
    }

    /// Whether OMC arguments select configuration, diagnostics, or another
    /// command that does not start an agent or team session.
    public static func omcLaunchIsNonLaunch(args: [String]) -> Bool {
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
            booleanOptions: [],
            valueOptions: []
        )
    }

    /// Whether OMX arguments select help, version, or a documented management command.
    public static func omxLaunchIsNonLaunch(args: [String]) -> Bool {
        guard let first = args.first else { return false }
        if informationalOptions.contains(first) { return true }
        return omxManagementCommands.contains(first)
    }

    private static func conservativeNonLaunchInvocation(
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
                if let allowedSubcommands = managementSubcommands[argument] {
                    guard index + 1 < args.count else { return false }
                    return allowedSubcommands.contains(args[index + 1])
                }
                return managementCommands.contains(argument)
            }
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if informationalOptions.contains(option) { return true }
            if valueOptions.contains(option) {
                if argument.contains("=") {
                    index += 1
                } else {
                    guard index + 1 < args.count else { return false }
                    index += 2
                }
                continue
            }
            guard booleanOptions.contains(option) else { return false }
            index += 1
        }
        return false
    }

    private static func claudeTeamsPolicyRecognizesOption(_ argument: String, policy: Policy) -> Bool {
        let name = optionName(argument)
        return policy.valueOptions.contains(name)
            || policy.optionalValueOptions.contains(name)
            || policy.booleanOptions.contains(name)
            || policy.variadicOptions.contains(name)
            || policy.droppedOptions.contains(name)
            || policy.rejectOptions.contains(name)
            || policy.promptBoundaryOptions.contains(name)
            || policy.droppedOptionPrefixes.contains(where: { argument.hasPrefix($0) })
            || runtimeOnlyOptionWidth(argument) != nil
    }

    private static func optionName(_ argument: String) -> String {
        guard let equals = argument.firstIndex(of: "=") else { return argument }
        return String(argument[..<equals])
    }

    private static let claudeTeamsManagementCommands: Set<String> = [
        "auth",
        "auto-mode",
        "doctor",
        "gateway",
        "install",
        "mcp",
        "plugin",
        "plugins",
        "project",
        "setup-token",
        "ultrareview",
        "update",
        "upgrade",
    ]

    private static let informationalOptions: Set<String> = ["--help", "-h", "--version", "-v", "-V"]

    private static let omxManagementCommands: Set<String> = [
        "agents",
        "agents-init",
        "auth",
        "cancel",
        "capabilities",
        "deepinit",
        "doctor",
        "help",
        "list",
        "session",
        "setup",
        "status",
        "uninstall",
        "update",
        "version",
    ]

    private static let claudeTeamsManagementDisqualifyingOptions: Set<String> = [
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
