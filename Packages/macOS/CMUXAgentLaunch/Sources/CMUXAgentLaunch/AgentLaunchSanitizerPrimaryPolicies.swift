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
            "--plugin-url",
            "--remote-control-session-name-prefix",
            "--session-id",
            "--setting-sources",
            "--settings",
            "--system-prompt",
            "--system-prompt-file",
            "--teammate-mode",
            "--tools"
        ],
        optionalValueOptions: [
            "--debug",
            "-d",
            "--from-pr",
            "--prompt-suggestions",
            "--remote-control",
            "--resume",
            "-r",
            "--worktree",
            "-w",
        ],
        // Claude booleans (from `claude --help`) pinned to width 1 so a following
        // one-word prompt is never inferred as the flag's value and replayed on
        // resume. Permission booleans are deliberately preserved for user-owned
        // restore: resuming your own session continues the original explicit
        // opt-in (https://github.com/manaflow-ai/cmux/issues/8066). Session-identity
        // and lifecycle booleans (--continue/-c, --fork-session, --bg) stay listed
        // in droppedOptions; being width-pinned here only keeps their drop exact.
        booleanOptions: [
            "--allow-dangerously-skip-permissions",
            "--ax-screen-reader",
            "--background",
            "--bare",
            "--bg",
            "--brief",
            "--chrome",
            "--continue",
            "-c",
            "--dangerously-skip-permissions",
            "--disable-slash-commands",
            "--exclude-dynamic-system-prompt-sections",
            "--forward-subagent-text",
            "--fork-session",
            "--ide",
            "--include-hook-events",
            "--include-partial-messages",
            "--no-chrome",
            "--replay-user-messages",
            "--safe-mode",
            "--strict-mcp-config",
            "--tmux",
            "--verbose"
        ],
        variadicOptions: [
            "--add-dir",
            "--allowedTools",
            "--allowed-tools",
            "--betas",
            "--dangerously-load-development-channels",
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
            "gateway",
            "install",
            "mcp",
            "plugin",
            "plugins",
            "project",
            "rc",
            "remote-control",
            "setup-token",
            "update",
            "upgrade",
            "ultrareview",
        ],
        droppedOptions: [
            // Replaying --bg/--background would turn an interactive pane restore
            // into a detached background-agent launch.
            "--background",
            "--bg",
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
            "--forward-subagent-text",
            "--no-session-persistence"
        ],
        scansOptionsPastPositionals: true,
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
        booleanOptions: [
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-bypass-hook-trust",
            "--no-alt-screen",
            "--oss",
            "--search",
            "--strict-config",
        ],
        variadicOptions: [
            "--image",
            "-i"
        ],
        nonRestorableCommands: [
            "archive",
            "delete",
            "doctor",
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
            "plugin",
            "remote-control",
            "sandbox",
            "debug",
            "apply",
            "a",
            "fork",
            "cloud",
            "exec-server",
            "features",
            "help",
            "unarchive",
            "update"
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

    static let piPolicy = Policy(
        valueOptions: [
            "--append-system-prompt",
            "--api-key",
            "--extension",
            "--fork",
            "--model",
            "--models",
            "--mode",
            "--prompt-template",
            "--provider",
            "--resume",
            "--session",
            "--session-id",
            "--session-dir",
            "--skill",
            "--system-prompt",
            "--theme",
            "--thinking",
            "--tools",
            "--exclude-tools",
            "--export",
            "--name",
            "-e",
            "-n",
            "-r",
            "-t",
            "-xt"
        ],
        optionalValueOptions: [
            "--list-models",
            "--resume",
            "-r"
        ],
        booleanOptions: [
            "--approve",
            "-a",
            "--no-approve",
            "-na",
            "--no-builtin-tools",
            "-nbt",
            "--no-context-files",
            "-nc",
            "--no-extensions",
            "-ne",
            "--no-prompt-templates",
            "-np",
            "--no-skills",
            "-ns",
            "--no-themes",
            "--no-tools",
            "-nt",
            "--offline",
            "--verbose",
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
            "--session-id",
            "-c",
            "-r"
        ],
        droppedOptionPrefixes: [
            "--api-key=",
            "--fork=",
            "--resume=",
            "--session=",
            "--session-id="
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

    /// OMP forwards Pi-compatible options but has additional model/profile controls whose
    /// values must not be interpreted as prompts. Keep these widths out of Pi/Campfire because
    /// Pi extensions may define the same spellings with different arity.
    static let ompPolicy: Policy = {
        var policy = piPolicy
        // OMP 16.x has no Pi-compatible `-xt` alias.
        policy.valueOptions.remove("-xt")
        policy.valueOptions.formUnion([
            "--approval-mode",
            "--config",
            "--cwd",
            "--hook",
            "--max-time",
            "--plan",
            "--plugin-dir",
            "--profile",
            "--skills",
            "--slow",
            "--smol",
        ])
        policy.booleanOptions.formUnion([
            "--advisor",
            "--allow-home",
            "--auto-approve",
            "--hide-thinking",
            "--no-extensions",
            "--no-lsp",
            "--no-pty",
            "--no-rules",
            "--no-skills",
            "--no-title",
            "--no-tools",
            "--print-thoughts",
        ])
        policy.valueOptions.insert("--alias")
        policy.rejectOptions.insert("--alias")
        policy.nonRestorableCommands.formUnion([
            "acp",
            "agents",
            "auth-broker",
            "auth-gateway",
            "bench",
            "commit",
            "completions",
            "dry-balance",
            "gallery",
            "gc",
            "grep",
            "grievances",
            "join",
            "models",
            "plugin",
            "read",
            "say",
            "search",
            "setup",
            "shell",
            "ssh",
            "stats",
            "tiny-models",
            "token",
            "ttsr",
            "usage",
            "worktree",
        ])
        return policy
    }()

    /// Campfire embeds vanilla pi and forwards unrecognized flags to it, so its
    /// policy is pi's plus the campfire-only surface. `--relay` is safe to
    /// replay (a relay URL, not a credential); `--join-as`/`--name` are
    /// joiner-only display names that make no sense on a host resume. An invite
    /// URL is a positional argument and is dropped by the default positional
    /// handling — it carries the lobby capability token and must never be
    /// persisted or replayed.
    static let campfirePolicy: Policy = {
        var policy = piPolicy
        policy.valueOptions.formUnion(["--relay", "--join", "--join-as", "--name"])
        policy.nonRestorableCommands.insert("init")
        policy.droppedOptions.formUnion(["--join", "--join-as", "--name", "--auto-exit"])
        policy.droppedOptionPrefixes.append(contentsOf: ["--join=", "--join-as=", "--name="])
        return policy
    }()

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
            "--runner-id",
            "--settings-file",
            "--visibility",
            "-l",
            "-m"
        ],
        optionalValueOptions: [
            "--plugin-ready-timeout",
        ],
        booleanOptions: [
            "--color",
            "--ide",
            "--no-archive-after-execute",
            "--no-color",
            "--no-ide",
            "--no-notifications",
            "--no-tui",
            "--notifications",
        ],
        nonRestorableCommands: [
            "clone",
            "config",
            "login",
            "logout",
            "mcp",
            "orb",
            "permissions",
            "permission",
            "projects",
            "review",
            "skill",
            "skills",
            "tool",
            "tools",
            "top",
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
            "--stream-json-thinking"
        ],
        rejectOptions: [
            "--execute",
            "--no-tui",
            "--print",
            "--runner-id",
            "--stream-json-input",
            "-V",
            "-x"
        ]
    )

    static let geminiPolicy = Policy(
        valueOptions: [
            "--model",
            "-m",
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
            "--session-file",
            "--session-id",
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
            "-r",
            "--worktree",
            "-w",
        ],
        booleanOptions: [
            "--debug",
            "-d",
            "--sandbox",
            "-s",
            "--screen-reader",
            "--skip-trust",
            "--yolo",
            "-y",
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
            "extension",
            "skills",
            "skill",
            "hooks",
            "hook",
            "gemma",
            "help"
        ],
        droppedOptions: [
            "--resume",
            "-r",
            "--session-file",
            "--session-id",
            "--worktree",
            "-w"
        ],
        droppedOptionPrefixes: [
            "--resume=",
            "--session-file=",
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
            "--list-extensions",
            "-l"
        ]
    )

    static let antigravityPolicy = Policy(
        valueOptions: [
            "--add-dir",
            "--conversation",
            "--log-file",
            "--model",
            "--new-project",
            "--print-timeout",
            "--project",
            "--prompt",
            "--prompt-interactive",
            "-p",
            "--sandbox",
        ],
        optionalValueOptions: [
            "--continue",
            "-c",
        ],
        booleanOptions: [
            "--dangerously-skip-permissions",
        ],
        nonRestorableCommands: [
            "changelog",
            "help",
            "install",
            "models",
            "plugin",
            "plugins",
            "update",
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "--conversation",
            "--new-project",
            "--project",
        ],
        droppedOptionPrefixes: [
            "--conversation=",
            "--new-project=",
            "--project=",
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
            "--add-dir",
            "--api-key",
            "-H",
            "--header",
            "--mode",
            "--model",
            "--output-format",
            "--plugin-dir",
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
        booleanOptions: [
            "--approve-mcps",
            "--auto-review",
            "--force",
            "-f",
            "--plan",
            "--skip-worktree-setup",
            "--trust",
            "--yolo",
        ],
        nonRestorableCommands: [
            "about",
            "create-chat",
            "generate-rule",
            "help",
            "install-shell-integration",
            "login",
            "logout",
            "mcp",
            "models",
            "plugin",
            "rule",
            "status",
            "uninstall-shell-integration",
            "update",
            "worker",
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
            "--list-models",
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
            "--agent",
            "--replay-limit"
        ],
        booleanOptions: [
            "--auto",
            "--mdns",
            "--mini",
            "--no-replay",
            "--print-logs",
            "--pure",
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

    /// OpenCode `run --interactive` is a multi-turn terminal mode with a
    /// different option surface from the root TUI. Startup inputs and remote
    /// connection material are consumed and dropped; the builder re-adds a
    /// canonical `--interactive --session <id>` selector.
    static let openCodeInteractiveRunPolicy = Policy(
        valueOptions: [
            "--agent",
            "--attach",
            "--command",
            "--dir",
            "--file",
            "-f",
            "--format",
            "--log-level",
            "--model",
            "-m",
            "--password",
            "-p",
            "--port",
            "--replay-limit",
            "--session",
            "-s",
            "--title",
            "--username",
            "-u",
            "--variant",
        ],
        booleanOptions: [
            "--auto",
            "--continue",
            "-c",
            "--dangerously-skip-permissions",
            "--demo",
            "--fork",
            "--interactive",
            "-i",
            "--mini",
            "--no-replay",
            "--print-logs",
            "--pure",
            "--replay",
            "--share",
            "--thinking",
            "--yolo",
        ],
        nonRestorableCommands: [],
        droppedOptions: [
            "--attach",
            "--command",
            "--continue",
            "-c",
            "--dir",
            "--file",
            "-f",
            "--fork",
            "--format",
            "--interactive",
            "-i",
            "--password",
            "-p",
            "--port",
            "--session",
            "-s",
            "--title",
            "--username",
            "-u",
        ],
        droppedOptionPrefixes: [
            "--attach=",
            "--command=",
            "--dir=",
            "--file=",
            "-f=",
            "--format=",
            "--password=",
            "-p=",
            "--port=",
            "--session=",
            "-s=",
            "--title=",
            "--username=",
            "-u=",
        ],
        rejectOptions: [
            "--demo",
            "--mini",
            "--replay-limit",
        ]
    )
}
