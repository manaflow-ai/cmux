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

    /// Pi (`pi-coding-agent`) policy. Pi launches as `pi [options] [@files...] [messages...]`
    /// where positional args are an initial prompt. For Vault resume we re-inject
    /// `--session <id>`; everything related to session selection / output mode /
    /// initial prompt must be stripped. User-set provider/model/system-prompt
    /// preferences are preserved so the resumed session keeps the same configuration.
    ///
    /// Boolean flags not listed in `valueOptions` (e.g. pi's `--no-tools`,
    /// `--verbose`, `--offline`, `--no-extensions`) flow through
    /// `preserveOptions`'s "unknown option = keep" default — `optionWidth`
    /// returns 1 for them and they're appended to the preserved result. Only
    /// flags we explicitly want to drop or reject need to appear below.
    static let piPolicy = Policy(
        valueOptions: [
            "--provider",
            "--model",
            "--api-key",
            "--system-prompt",
            "--append-system-prompt",
            "--mode",
            "--session",
            "--fork",
            "--session-dir",
            "--models",
            "--tools",
            "-t",
            "--thinking",
            "--extension",
            "-e",
            "--skill",
            "--prompt-template",
            "--theme"
        ],
        optionalValueOptions: [],
        variadicOptions: [
            "--append-system-prompt",
            "--extension",
            "-e",
            "--skill",
            "--prompt-template",
            "--theme"
        ],
        nonRestorableCommands: [
            // pi subcommands that don't start a session
            "install",
            "remove",
            "uninstall",
            "update",
            "list",
            "config"
        ],
        droppedOptions: [
            // Session selection — Vault re-injects --session <id>
            "--session",
            "--fork",
            "--continue",
            "-c",
            "--resume",
            "-r",
            "--no-session",
            // One-shot prompt flags — drop so the recorded launch can be
            // resumed as an interactive `pi --session <id>` session.
            "--print",
            "-p",
            // Credentials — never persist into a recorded launch command
            // (Vault stores commands and re-emits them for resume).
            // `--api-key` stays in `valueOptions` above so the parser still
            // consumes its trailing value; listing it here drops the flag
            // from the sanitized output. Mirrors `cursorPolicy`.
            "--api-key"
        ],
        droppedOptionPrefixes: [
            "--session=",
            "--fork=",
            "--api-key="
        ],
        rejectOptions: [
            // These are incompatible with restoring an interactive session
            "--export",
            "--list-models",
            "--help",
            "-h",
            "--version",
            "-v"
        ],
        preserveFirstPositional: false
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
