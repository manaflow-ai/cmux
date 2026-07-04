import Foundation

extension AgentLaunchSanitizer {
    static let copilotPolicy = Policy(
        valueOptions: [
            "--add-dir",
            "--add-github-mcp-tool",
            "--add-github-mcp-toolset",
            "--additional-mcp-config",
            "--agent",
            "--allow-tool",
            "--allow-url",
            "--available-tools",
            "--bash-env",
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
            "--secret-env-vars",
            "--share",
            "--stream"
        ],
        optionalValueOptions: [
            "--allow-tool",
            "--allow-url",
            "--available-tools",
            "--bash-env",
            "--connect",
            "--deny-tool",
            "--deny-url",
            "--excluded-tools",
            "--mouse",
            "--resume",
            "--secret-env-vars",
            "--share"
        ],
        variadicOptions: [
            "--add-dir",
            "--add-github-mcp-tool",
            "--add-github-mcp-toolset",
            "--additional-mcp-config",
            "--allow-tool",
            "--allow-url",
            "--available-tools",
            "--deny-tool",
            "--deny-url",
            "--disable-mcp-server",
            "--excluded-tools",
            "--plugin-dir",
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
            "--resume"
        ],
        droppedOptionPrefixes: [
            "--connect=",
            "--interactive=",
            "-i=",
            "--resume="
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
            "--permission-mode",
            "--plugin-dir",
            "--port",
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
        variadicOptions: [
            "--add-dir",
            "--allowedTools",
            "--dangerously-load-development-channels",
            "--disallowedTools",
            "--mcp-config",
            "--plugin-dir"
        ],
        variadicValuePrefixes: [
            "--dangerously-load-development-channels": ["server:"]
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
            "--serve"
        ]
    )

    static let factoryPolicy = Policy(
        valueOptions: [
            "--append-system-prompt",
            "--append-system-prompt-file",
            "--cwd",
            "--fork",
            "--resume",
            "-r",
            "--settings",
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
        ]
    )

    static let qoderPolicy = Policy(
        valueOptions: [
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
            "--session-id",
            "--setting-sources",
            "--settings",
            "--system-prompt",
            "--tools",
            "--workspace",
            "-w"
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
            "--session-id"
        ],
        droppedOptionPrefixes: [
            "--resume=",
            "-r=",
            "--session-id="
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
            "-i"
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
            "--format",
            "-f",
            "--resume-id",
            "--trust-tools",
            "--wrap"
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
            "--restore"
        ],
        nonRestorableCommands: [
            "auth",
            "config",
            "help",
            "mcp",
            "server",
            "update",
            "upgrade",
            "version"
        ],
        droppedOptions: [
            "--restore"
        ],
        droppedOptionPrefixes: [
            "--restore="
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
            "--resume",
            "-r",
            "--skills",
            "-s",
            "--source",
            "--toolsets",
            "-t",
            "--worktree",
            "-w"
        ],
        optionalValueOptions: [
            "--continue",
            "-c"
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
            "--list-toolsets"
        ]
    )
}
