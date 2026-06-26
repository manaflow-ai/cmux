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
            "--append-system-prompt-file",
            "--betas",
            "--dangerously-load-development-channels",
            "--debug-file",
            "--disallowedTools",
            "--disallowed-tools",
            "--effort",
            "--fallback-model",
            "--file",
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
            "--system-prompt-file",
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
            // Claude Code accepts multiple `server:<name>` values here. Without
            // a variadic entry preserveOptions consumes only the first value and
            // the break-on-positional branch silently drops every later flag
            // from the rebuilt resume command (see issue #6235). Consumption is
            // constrained to the `server:` grammar via variadicValuePrefixes so
            // a trailing startup prompt is not swallowed as a channel value.
            "--dangerously-load-development-channels",
            "--disallowedTools",
            "--disallowed-tools",
            "--file",
            "--mcp-config",
            "--tools"
        ],
        variadicValuePrefixes: [
            // Channel values are always `server:<name>`. Restricting variadic
            // consumption to that prefix preserves every value (issue #6235)
            // while still treating a following positional (e.g. a startup
            // prompt) as the prompt boundary, so the sanitizer never replays it.
            "--dangerously-load-development-channels": ["server:"]
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
            "--file",
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
            "--file=",
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
            "-i"
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
            "--image",
            "-i",
            "--remote",
            "--remote-auth-token-env",
            "--all"
        ],
        droppedOptionPrefixes: [
            "--remote=",
            "--remote-auth-token-env="
        ],
        resumeSubcommand: "resume"
    )

    static let grokPolicy = Policy(
        valueOptions: [
            "--agent",
            "--agents",
            "--allow",
            "--cwd",
            "--deny",
            "--disallowed-tools",
            "--effort",
            "--max-turns",
            "--model",
            "-m",
            "--permission-mode",
            "--reasoning-effort",
            "--resume",
            "-r",
            "--rules",
            "--sandbox",
            "--system-prompt-override",
            "--tools",
            "--worktree",
            "-w"
        ],
        optionalValueOptions: [
            "--resume",
            "-r",
            "--worktree",
            "-w"
        ],
        nonRestorableCommands: [
            "agent",
            "help",
            "import",
            "inspect",
            "leader",
            "login",
            "mcp",
            "memory",
            "models",
            "sessions",
            "setup",
            "share",
            "ssh",
            "trace",
            "update",
            "version",
            "v",
            "worktree"
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "--restore-code",
            "--resume",
            "-r",
            "--worktree",
            "-w"
        ],
        droppedOptionPrefixes: [
            "--resume=",
            "-r=",
            "--worktree=",
            "-w="
        ],
        rejectOptions: [
            "--best-of-n",
            "--output-format",
            "--prompt-file",
            "--prompt-json",
            "--single",
            "-p"
        ]
    )

    static let piPolicy = Policy(
        valueOptions: [
            "--append-system-prompt",
            "--api-key",
            "--extension",
            "--fork",
            "--model",
            "--models",
            "--prompt-template",
            "--provider",
            "--resume",
            "--session",
            "--session-dir",
            "--skill",
            "--system-prompt",
            "--theme",
            "--thinking",
            "--tools",
            "-e",
            "-r",
            "-t"
        ],
        nonRestorableCommands: [
            "config",
            "help",
            "install",
            "list",
            "login",
            "logout",
            "remove",
            "uninstall",
            "update"
        ],
        droppedOptions: [
            "--api-key",
            "--continue",
            "--fork",
            "--resume",
            "--session",
            "-c",
            "-r"
        ],
        droppedOptionPrefixes: [
            "--api-key=",
            "--fork=",
            "--resume=",
            "--session="
        ],
        rejectOptions: [
            "--export",
            "--list-models",
            "--mode",
            "--no-session",
            "--print",
            "--prompt",
            "--version",
            "-h",
            "-p",
            "-v"
        ]
    )

    static let ampPolicy = Policy(
        valueOptions: [
            "--effort",
            // --label takes a value; listed here AND in droppedOptions so the
            // sanitizer consumes the value too (otherwise it slips through as
            // a positional).
            "--label",
            "--log-file",
            "--log-level",
            "--mcp-config",
            "--mode",
            "--settings-file",
            "--visibility",
            "-l",
            "-m"
        ],
        nonRestorableCommands: [
            "login",
            "logout",
            "mcp",
            "permissions",
            "permission",
            "review",
            "skill",
            "skills",
            "tool",
            "tools",
            "update",
            "up",
            "usage",
            "version"
        ],
        droppedOptions: [
            "--archive",
            "--label",
            "-l",
            "--stream-json",
            "--stream-json-input",
            "--stream-json-thinking"
        ],
        rejectOptions: [
            "--execute",
            "--print",
            "-V",
            "-x"
        ]
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

    static let antigravityPolicy = Policy(
        valueOptions: [
            "--add-dir",
            "--conversation",
            "--log-file",
            "--print-timeout",
            "--prompt",
            "-p",
            "--sandbox",
        ],
        optionalValueOptions: [
            "--continue",
            "-c",
        ],
        nonRestorableCommands: [
            "changelog",
            "help",
            "install",
            "plugin",
            "plugins",
            "update",
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "--conversation",
        ],
        droppedOptionPrefixes: [
            "--conversation=",
        ],
        rejectOptions: [
            "--prompt",
            "-p",
            "--prompt-interactive",
            "-i",
            "--print",
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
            "--file",
            "-f",
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
            "--file",
            "-f",
            "--fork",
            "--session",
            "-s",
            "--prompt"
        ],
        droppedOptionPrefixes: [
            "--file=",
            "-f=",
            "--fork=",
            "--session=",
            "--prompt="
        ],
        preserveFirstPositional: true
    )
}
