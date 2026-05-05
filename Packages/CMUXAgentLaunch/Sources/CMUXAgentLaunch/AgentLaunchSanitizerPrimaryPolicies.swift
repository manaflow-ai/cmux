import Foundation

extension AgentLaunchSanitizer {
    static let claudePolicy = Policy(
        valueOptions: [
            "--add-dir",
            "--agent",
            "--agents",
            "--allowedTools",
            "--allowed-tools",
            "--append-system-prompt",
            "--betas",
            "--debug-file",
            "--disallowedTools",
            "--disallowed-tools",
            "--effort",
            "--fallback-model",
            "--file",
            "--fork-session",
            "--from-pr",
            "--input-format",
            "--json-schema",
            "--max-budget-usd",
            "--mcp-config",
            "--model",
            "--name",
            "-n",
            "--output-format",
            "--permission-mode",
            "--plugin-dir",
            "--remote-control-session-name-prefix",
            "--resume",
            "-r",
            "--session-id",
            "--setting-sources",
            "--settings",
            "--system-prompt",
            "--teammate-mode",
            "--tmux",
            "--tools",
            "--worktree",
            "-w"
        ],
        optionalValueOptions: [
            "--debug"
        ],
        variadicOptions: [
            "--add-dir",
            "--allowedTools",
            "--allowed-tools",
            "--betas",
            "--disallowedTools",
            "--disallowed-tools",
            "--file",
            "--mcp-config",
            "--tools"
        ],
        nonRestorableCommands: [
            "agents",
            "auth",
            "auto-mode",
            "api-key",
            "config",
            "doctor",
            "install",
            "mcp",
            "plugin",
            "plugins",
            "rc",
            "remote-control",
            "setup-token",
            "update",
            "upgrade"
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "--fork-session",
            "--from-pr",
            "--resume",
            "-r",
            "--session-id",
            "--tmux",
            "--worktree",
            "-w"
        ],
        droppedOptionPrefixes: [
            "--fork-session=",
            "--from-pr=",
            "--resume=",
            "--session-id=",
            "--tmux=",
            "--worktree="
        ],
        rejectOptions: [
            "--print",
            "-p",
            "--no-session-persistence"
        ],
        skipClaudeHookSettings: true
    )

    static let codexPolicy = Policy(
        valueOptions: [
            "--config",
            "-c",
            "--remote",
            "--remote-auth-token-env",
            "--image",
            "-i",
            "--model",
            "-m",
            "--local-provider",
            "--profile",
            "-p",
            "--sandbox",
            "-s",
            "--ask-for-approval",
            "-a",
            "--cd",
            "-C",
            "--add-dir",
            "--enable",
            "--disable"
        ],
        variadicOptions: [
            "--image",
            "-i",
            "--add-dir"
        ],
        nonRestorableCommands: [
            "exec",
            "e",
            "review",
            "login",
            "logout",
            "mcp",
            "mcp-server",
            "app-server",
            "app",
            "completion",
            "sandbox",
            "debug",
            "apply",
            "a",
            "fork",
            "cloud",
            "exec-server",
            "features",
            "help"
        ],
        droppedOptions: [
            "--last",
            "--all"
        ],
        resumeSubcommand: "resume"
    )

    static let geminiPolicy = Policy(
        valueOptions: [
            "--model",
            "-m",
            "--sandbox",
            "-s",
            "--approval-mode",
            "--policy",
            "--admin-policy",
            "--allowed-mcp-server-names",
            "--allowed-tools",
            "--extensions",
            "-e",
            "--include-directories",
            "--resume",
            "-r",
            "--session-id",
            "--worktree",
            "-w",
            "--prompt",
            "-p",
            "--prompt-interactive",
            "-i",
            "--delete-session",
            "--output-format",
            "-o"
        ],
        optionalValueOptions: [
            "--resume",
            "-r"
        ],
        variadicOptions: [
            "--policy",
            "--admin-policy",
            "--allowed-mcp-server-names",
            "--allowed-tools",
            "--extensions",
            "-e",
            "--include-directories"
        ],
        nonRestorableCommands: [
            "mcp",
            "extensions",
            "skills",
            "hooks",
            "gemma",
            "help"
        ],
        droppedOptions: [
            "--resume",
            "-r",
            "--session-id",
            "--worktree",
            "-w"
        ],
        droppedOptionPrefixes: [
            "--resume=",
            "--session-id=",
            "--worktree="
        ],
        rejectOptions: [
            "--prompt",
            "-p",
            "--prompt-interactive",
            "-i",
            "--list-sessions",
            "--delete-session",
            "--output-format",
            "-o",
            "--raw-output",
            "--accept-raw-output-risk",
            "--acp",
            "--experimental-acp",
            "--list-extensions"
        ]
    )

    static let cursorPolicy = Policy(
        valueOptions: [
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
            "--worktree-base"
        ],
        optionalValueOptions: [
            "-w",
            "--resume",
            "--worktree"
        ],
        nonRestorableCommands: [
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
            "whoami"
        ],
        droppedOptions: [
            "--api-key",
            "-H",
            "--header",
            "--continue",
            "--resume",
            "--workspace",
            "-w",
            "--worktree",
            "--worktree-base",
            "--skip-worktree-setup"
        ],
        droppedOptionPrefixes: [
            "--api-key=",
            "--header=",
            "-H=",
            "--resume=",
            "--workspace=",
            "--worktree=",
            "--worktree-base="
        ],
        rejectOptions: [
            "--cloud",
            "--output-format",
            "--print",
            "-p",
            "--stream-partial-output"
        ],
        resumeSubcommand: "resume"
    )

    static let openCodePolicy = Policy(
        valueOptions: [
            "--log-level",
            "--port",
            "--hostname",
            "--mdns-domain",
            "--cors",
            "--model",
            "-m",
            "--session",
            "-s",
            "--prompt",
            "--agent"
        ],
        variadicOptions: [
            "--cors"
        ],
        nonRestorableCommands: [
            "completion",
            "acp",
            "mcp",
            "attach",
            "run",
            "debug",
            "providers",
            "auth",
            "agent",
            "upgrade",
            "uninstall",
            "serve",
            "web",
            "models",
            "stats",
            "export",
            "import",
            "pr",
            "github",
            "session",
            "plugin",
            "plug",
            "db"
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "--fork",
            "--session",
            "-s",
            "--prompt"
        ],
        droppedOptionPrefixes: [
            "--session=",
            "--prompt="
        ],
        preserveFirstPositional: true
    )
}
