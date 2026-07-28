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
            guard claudeTeamsPolicyRecognizesOption(argument, policy: policy),
                  !claudeTeamsManagementDisqualifyingOptions.contains(optionName(argument)) else {
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

    /// Whether OpenCode arguments select help, version, or a documented management command.
    public static func omoLaunchIsNonLaunch(args: [String]) -> Bool {
        conservativeNonLaunchInvocation(
            args: args,
            managementCommands: [
                "agent",
                "auth",
                "completion",
                "db",
                "debug",
                "mcp",
                "models",
                "plugin",
                "providers",
                "stats",
                "uninstall",
                "upgrade",
            ],
            booleanOptions: ["--print-logs", "--pure"],
            valueOptions: ["--log-level"]
        )
    }

    /// Whether OMX arguments select help, version, or a documented management command.
    public static func omxLaunchIsNonLaunch(args: [String]) -> Bool {
        conservativeNonLaunchInvocation(
            args: args,
            managementCommands: [
                "agents",
                "agents-init",
                "auth",
                "deepinit",
                "doctor",
                "help",
                "list",
                "setup",
                "status",
                "uninstall",
                "update",
                "version",
            ],
            booleanOptions: [
                "--clear-merge-agents-policy",
                "--disable-team",
                "--dry-run",
                "--enable-team",
                "--force",
                "--keep-config",
                "--legacy",
                "--merge-agents",
                "--no-mcp",
                "--no-merge-agents",
                "--plugin",
                "--purge",
                "--team",
                "--verbose",
                "--with-mcp",
            ],
            valueOptions: ["--install-mode", "--mcp", "--scope", "--team-mode"]
        )
    }

    private static func conservativeNonLaunchInvocation(
        args: [String],
        managementCommands: Set<String>,
        booleanOptions: Set<String>,
        valueOptions: Set<String>
    ) -> Bool {
        let informationalOptions: Set<String> = ["--help", "-h", "--version", "-v", "-V"]
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" { return false }
            if !argument.hasPrefix("-") || argument == "-" {
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
        "agents",
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
