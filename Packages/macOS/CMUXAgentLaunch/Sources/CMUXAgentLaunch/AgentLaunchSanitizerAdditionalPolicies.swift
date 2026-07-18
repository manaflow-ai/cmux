import Foundation

extension AgentLaunchSanitizer {
    static let copilotPolicy = Policy(
        valueOptions: [
            "--attachment",
            "--add-dir",
            "--add-github-mcp-tool",
            "--add-github-mcp-toolset",
            "--additional-mcp-config",
            "--agent",
            "--allow-tool",
            "--allow-url",
            "--available-tools",
            "-C",
            "--connect",
            "--deny-tool",
            "--deny-url",
            "--disable-mcp-server",
            "--effort",
            "--excluded-tools",
            "--interactive",
            "-i",
            "--log-dir",
            "--log-level",
            "--max-autopilot-continues",
            "--mode",
            "--model",
            "-n",
            "--name",
            "--output-format",
            "--plugin-dir",
            "--prompt",
            "-p",
            "--reasoning-effort",
            "--resume",
            "--session-id",
            "--secret-env-vars",
            "--share",
            "--stream"
        ],
        optionalValueOptions: [
            "--allow-tool",
            "--allow-url",
            "--available-tools",
            "--connect",
            "--deny-tool",
            "--deny-url",
            "--excluded-tools",
            "--resume",
            "--secret-env-vars",
            "--share",
            "--worktree",
            "-w"
        ],
        booleanOptions: [
            "--allow-all",
            "--allow-all-mcp-server-instructions",
            "--allow-all-paths",
            "--allow-all-tools",
            "--allow-all-urls",
            "--autopilot",
            "--banner",
            "--bash-env",
            "--continue",
            "--disable-builtin-mcps",
            "--disallow-temp-dir",
            "--enable-all-github-mcp-tools",
            "--enable-memory",
            "--enable-reasoning-summaries",
            "--experimental",
            "--mouse",
            "--no-ask-user",
            "--no-auto-update",
            "--no-banner",
            "--no-bash-env",
            "--no-color",
            "--no-custom-instructions",
            "--no-experimental",
            "--no-mouse",
            "--no-remote",
            "--no-remote-export",
            "--no-sandbox",
            "--plain-diff",
            "--plan",
            "--remote",
            "--remote-export",
            "--sandbox",
            "--screen-reader",
            "--show-secrets",
            "--yolo",
        ],
        variadicOptions: [
            "--allow-tool",
            "--allow-url",
            "--available-tools",
            "--deny-tool",
            "--deny-url",
            "--excluded-tools",
            "--secret-env-vars"
        ],
        nonRestorableCommands: [
            "completion",
            "help",
            "init",
            "login",
            "mcp",
            "plugin",
            "update",
            "version"
        ],
        droppedOptions: [
            "--connect",
            "--continue",
            "--interactive",
            "-i",
            "--resume",
            "--session-id",
            "--attachment",
            "--worktree",
            "-w"
        ],
        droppedOptionPrefixes: [
            "--connect=",
            "--interactive=",
            "-i=",
            "--resume=",
            "--session-id=",
            "--attachment=",
            "--worktree=",
            "-w="
        ],
        rejectOptions: [
            "--acp",
            "--output-format",
            "--prompt",
            "-p",
            "--share",
            "--share-gist",
            "--silent",
            "-s"
        ]
    )

    static let codeBuddyPolicy = Policy(
        valueOptions: [
            "--add-dir",
            "--agent",
            "--agents",
            "--allowedTools",
            "--append-system-prompt",
            "--channels",
            "--dangerously-load-development-channels",
            "--disallowedTools",
            "--fallback-model",
            "-H",
            "--header",
            "--image-to-image-model",
            "--input-format",
            "--json-schema",
            "--max-turns",
            "--mcp-config",
            "--model",
            "--name",
            "--output-format",
            "--permission-prompt-tool",
            "--permission-mode",
            "--plugin-dir",
            "--port",
            "--prewarm-id",
            "--resume",
            "-r",
            "--sandbox",
            "--sandbox-id",
            "--setting-sources",
            "--settings",
            "--session-id",
            "--subagent-permission-mode",
            "--system-prompt",
            "--system-prompt-file",
            "--teleport",
            "--text-to-image-model",
            "--tools",
            "--worktree",
            "-w",
            "--worktree-branch"
        ],
        optionalValueOptions: [
            "--debug",
            "--resume",
            "-r",
            "--sandbox",
            "--worktree",
            "-w"
        ],
        booleanOptions: [
            "--background",
            "--bg",
            "--continue",
            "-c",
            "--dangerously-skip-permissions",
            "--fork-session",
            "--ide",
            "--include-partial-messages",
            "--prewarm",
            "--serve",
            "--strict-mcp-config",
            "--tmux",
            "--tmux-classic",
            "--verbose",
        ],
        variadicOptions: [
            "--add-dir",
            "--allowedTools",
            "--disallowedTools",
            "--mcp-config",
            "--plugin-dir"
        ],
        nonRestorableCommands: [
            "attach",
            "config",
            "daemon",
            "doctor",
            "help",
            "install",
            "kill",
            "logs",
            "mcp",
            "plugin",
            "ps",
            "sandbox",
            "update"
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "-H",
            "--header",
            "--fork-session",
            "--name",
            "--resume",
            "-r",
            "--session-id",
            "--tmux",
            "--tmux-classic",
            "--worktree",
            "-w",
            "--worktree-branch"
        ],
        droppedOptionPrefixes: [
            "--header=",
            "-H=",
            "--name=",
            "--resume=",
            "-r=",
            "--session-id=",
            "--worktree=",
            "-w=",
            "--worktree-branch="
        ],
        rejectOptions: [
            "--acp",
            "--background",
            "--bg",
            "--input-format",
            "--output-format",
            "--print",
            "-p",
            "--prewarm",
            "--serve"
        ]
    )

    static let factoryPolicy = Policy(
        valueOptions: [
            "--append-system-prompt",
            "--append-system-prompt-file",
            "--auto",
            "--cwd",
            "--disabled-tools",
            "--enabled-tools",
            "--file",
            "-f",
            "--fork",
            "--input-format",
            "--log-group-id",
            "--model",
            "-m",
            "--output-format",
            "-o",
            "--reasoning-effort",
            "--resume",
            "-r",
            "--settings",
            "--spec-model",
            "--spec-reasoning-effort",
            "--tag",
            "--validator-model",
            "--validator-reasoning-effort",
            "--worker-model",
            "--worker-reasoning-effort",
            "--worktree",
            "-w",
            "--worktree-dir"
        ],
        optionalValueOptions: [
            "--resume",
            "-r",
            "--worktree",
            "-w"
        ],
        booleanOptions: [
            "--mission",
            "--skip-permissions-unsafe",
            "--use-spec",
        ],
        nonRestorableCommands: [
            "computer",
            "daemon",
            "exec",
            "find",
            "help",
            "mcp",
            "plugin",
            "search",
            "update"
        ],
        droppedOptions: [
            "--fork",
            "--resume",
            "-r",
            "--worktree",
            "-w",
            "--worktree-dir"
        ],
        droppedOptionPrefixes: [
            "--fork=",
            "--resume=",
            "-r=",
            "--worktree=",
            "-w=",
            "--worktree-dir="
        ],
        rejectOptions: [
            "--list-tools",
        ]
    )

    static let qoderPolicy = Policy(
        valueOptions: [
            "--add-dir",
            "--agent",
            "--agents",
            "--allowed-mcp-server-names",
            "--allowed-tools",
            "--append-system-prompt",
            "--attachment",
            "--cwd",
            "--delete-session",
            "--disallowed-tools",
            "--input-format",
            "--max-turns",
            "--max-output-tokens",
            "--mcp-config",
            "--model",
            "-m",
            "--name",
            "-n",
            "--output-format",
            "-o",
            "-f",
            "--permission-mode",
            "--plugin-dir",
            "--prompt-interactive",
            "-i",
            "--resume",
            "-r",
            "--remote",
            "--session-id",
            "--setting-sources",
            "--settings",
            "--system-prompt",
            "--tools",
            "--workspace",
            "-w"
        ],
        optionalValueOptions: [
            "--worktree",
        ],
        booleanOptions: [
            "--continue",
            "-c",
            "--fork-session",
            "--yolo",
        ],
        variadicOptions: [
            "--allowed-mcp-server-names",
            "--allowed-tools",
            "--attachment",
            "--disallowed-tools",
            "--mcp-config",
            "--plugin-dir",
            "--setting-sources",
            "--tools"
        ],
        nonRestorableCommands: [
            "agent",
            "agents",
            "feedback",
            "help",
            "hook",
            "hooks",
            "login",
            "mcp",
            "plugin",
            "plugins",
            "skill",
            "skills",
            "update"
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "--fork-session",
            "--resume",
            "-r",
            "--session-id",
            "--worktree"
        ],
        droppedOptionPrefixes: [
            "--resume=",
            "-r=",
            "--session-id=",
            "--worktree="
        ],
        rejectOptions: [
            "--acp",
            "--delete-session",
            "--input-format",
            "--list-sessions",
            "--output-format",
            "-o",
            "-f",
            "--print",
            "-p",
            "--prompt-interactive",
            "-i",
            "--remote"
        ]
    )

    // kiro-cli flag widths for session restore. `--resume` / `-r` are boolean
    // (resume the previous conversation from the current directory; they take
    // no value), so they live in droppedOptions only — dropping them must not
    // consume a following token. The session-id variant `--resume-id <id>`
    // takes a value and is in both valueOptions and droppedOptions so the id is
    // dropped with the flag. kiro-cli exposes no optional-value or variadic
    // (single flag carrying multiple space-separated values) flags, so those
    // Policy fields are intentionally omitted.
    static let kiroPolicy = Policy(
        valueOptions: [
            "--agent",
            "--delete-session",
            "--effort",
            "--format",
            "-f",
            "--resume-id",
            "--trust-tools",
            "--wrap"
        ],
        booleanOptions: [
            "--require-mcp-startup",
            "--trust-all-tools",
        ],
        nonRestorableCommands: [
            "agent",
            "diagnostic",
            "doctor",
            "inline",
            "integrations",
            "issue",
            "login",
            "logout",
            "mcp",
            "settings",
            "theme",
            "translate",
            "update",
            "version",
            "whoami"
        ],
        droppedOptions: [
            "--delete-session",
            "--format",
            "-f",
            "--resume",
            "-r",
            "--resume-id"
        ],
        droppedOptionPrefixes: [
            "--delete-session=",
            "--format=",
            "-f=",
            "--resume-id="
        ],
        rejectOptions: [
            "--list-models",
            "--list-sessions",
            "--no-interactive",
            "--resume-picker"
        ]
    )

    static let rovoDevPolicy = Policy(
        valueOptions: [
            "--config",
            "--config-file",
            "--model",
            "--model-id",
            "--restore"
        ],
        optionalValueOptions: [
            "--restore",
            "--worktree",
        ],
        booleanOptions: [
            "--web",
            "--yolo",
        ],
        nonRestorableCommands: [
            "auth",
            "config",
            "help",
            "mcp",
            "server",
            "serve",
            "update",
            "upgrade",
            "version"
        ],
        droppedOptions: [
            "--restore",
            "--worktree",
        ],
        droppedOptionPrefixes: [
            "--restore=",
            "--worktree=",
        ],
        rejectOptions: [
            "--prompt",
            "-p",
            "--prompt-interactive",
            "-i",
            "--print",
            "--input-format",
            "--output-format",
            "-o"
        ]
    )

    static let hermesAgentPolicy = Policy(
        // Boolean flags such as --tui pass through by default unless they are
        // explicitly rejected or dropped below.
        valueOptions: [
            "--api-key",
            "--base-url",
            "--image",
            "--max-turns",
            "--model",
            "-m",
            "--profile",
            "-p",
            "--provider",
            "--query",
            "-q",
            "--resume",
            "-r",
            "--skills",
            "-s",
            "--source",
            "--toolsets",
            "-t"
        ],
        optionalValueOptions: [
            "--continue",
            "-c"
        ],
        booleanOptions: [
            "--accept-hooks",
            "--checkpoints",
            "--dev",
            "--ignore-rules",
            "--ignore-user-config",
            "--pass-session-id",
            "--tui",
            "--worktree",
            "-w",
            "--yolo",
        ],
        nonRestorableCommands: [],
        droppedOptions: [
            "--api-key",
            "--continue",
            "-c",
            "--image",
            "--resume",
            "-r",
            "--source",
            "--verbose",
            "-v",
            "--worktree",
            "-w"
        ],
        droppedOptionPrefixes: [
            "--api-key=",
            "--continue=",
            "-c=",
            "--image=",
            "--resume=",
            "-r=",
            "--source=",
            "--worktree=",
            "-w="
        ],
        rejectOptions: [
            "--oneshot",
            "-z",
            "--query",
            "-q",
            "--quiet",
            "-Q",
            "--list-tools",
            "--list-toolsets",
            "--version",
            "-V",
        ]
    )
}
