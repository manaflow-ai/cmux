import CMUXAgentLaunch
import Testing

@Suite("Current provider CLI contracts")
struct ProviderCurrentVersionContractTests {
    @Test("Claude 2.1.214 utility commands and option widths")
    func claudeCurrentContracts() {
        for command in ["gateway", "project"] {
            let arguments = ["claude", command]
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "claude", arguments: arguments, kind: "claude"
                ) == .nonSession,
                "claude \(command)"
            )
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "claude", fallbackKind: "claude"
                ) == nil,
                "claude \(command)"
            )
        }

        let ultrareview = ["claude", "ultrareview", "main"]
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "claude", arguments: ultrareview, kind: "claude"
            ) == .oneShot
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ultrareview, launcher: "claude", fallbackKind: "claude"
            ) == nil
        )

        let safeFlags = [
            "claude",
            "--bare",
            "--safe-mode",
            "--brief",
            "--plugin-url", "https://example.test/plugin.zip",
            "--name", "review agent",
            "--prompt-suggestions", "true",
            "--model", "sonnet",
        ]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                safeFlags, launcher: "claude", fallbackKind: "claude"
            ) == safeFlags
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["claude", "--prompt-suggestions", "--model", "sonnet"],
                launcher: "claude",
                fallbackKind: "claude"
            ) == ["claude", "--prompt-suggestions", "--model", "sonnet"]
        )
    }

    @Test("Claude 2.1.214 optional selectors preserve adjacent options")
    func claudeCurrentOptionalSelectorsPreserveAdjacentOptions() {
        for selector in ["--resume", "--from-pr", "--worktree", "-w", "--tmux"] {
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    ["claude", selector, "--model", "sonnet"],
                    launcher: "claude",
                    fallbackKind: "claude"
                ) == ["claude", "--model", "sonnet"],
                "direct \(selector)"
            )
        }
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["claude", "--remote-control", "--model", "sonnet"],
                launcher: "claude",
                fallbackKind: "claude"
            ) == ["claude", "--remote-control", "--model", "sonnet"]
        )

        for arguments in [
            ["--resume", "session-1", "--model", "sonnet"],
            ["--from-pr", "123", "--model", "sonnet"],
            ["--worktree", "feature-a", "--model", "sonnet"],
            ["-w", "feature-b", "--model", "sonnet"],
            ["--tmux=classic", "--model", "sonnet"],
        ] {
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    ["claude"] + arguments,
                    launcher: "claude",
                    fallbackKind: "claude"
                ) == ["claude", "--model", "sonnet"],
                "direct \(arguments)"
            )
        }
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["claude", "--remote-control", "pairing", "--model", "sonnet"],
                launcher: "claude",
                fallbackKind: "claude"
            ) == ["claude", "--remote-control", "pairing", "--model", "sonnet"]
        )

        for selector in ["--resume", "--from-pr", "--tmux"] {
            #expect(
                AgentLaunchSanitizer.preservedClaudeTeamsLaunchArguments(
                    args: [selector, "--model", "sonnet"]
                ) == ["--model", "sonnet"],
                "teams \(selector)"
            )
        }
        for selector in ["--worktree", "-w", "--remote-control"] {
            #expect(
                AgentLaunchSanitizer.preservedClaudeTeamsLaunchArguments(
                    args: [selector, "--model", "sonnet"]
                ) == [selector, "--model", "sonnet"],
                "teams \(selector)"
            )
        }
        for arguments in [
            ["--resume", "session-1", "--model", "sonnet"],
            ["--from-pr", "123", "--model", "sonnet"],
            ["--tmux=classic", "--model", "sonnet"],
        ] {
            #expect(
                AgentLaunchSanitizer.preservedClaudeTeamsLaunchArguments(args: arguments)
                    == ["--model", "sonnet"],
                "teams \(arguments)"
            )
        }
        for arguments in [
            ["--worktree", "feature-a", "--model", "sonnet"],
            ["-w", "feature-b", "--model", "sonnet"],
            ["--remote-control", "pairing", "--model", "sonnet"],
        ] {
            #expect(
                AgentLaunchSanitizer.preservedClaudeTeamsLaunchArguments(args: arguments)
                    == arguments,
                "teams \(arguments)"
            )
        }
    }

    @Test("Cursor 2026.07.16 paths and booleans")
    func cursorCurrentContracts() {
        let launch = [
            "cursor-agent", "agent",
            "--add-dir", "/tmp/source tree",
            "--plugin-dir", "/tmp/plugin tree",
            "--force",
            "-f",
            "--yolo",
            "--approve-mcps",
            "--trust",
            "--skip-worktree-setup",
            "--model", "composer-1.5",
            "initial prompt",
        ]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                launch, launcher: "cursor", fallbackKind: "cursor"
            ) == [
                "cursor-agent",
                "--add-dir", "/tmp/source tree",
                "--plugin-dir", "/tmp/plugin tree",
                "--force",
                "-f",
                "--yolo",
                "--approve-mcps",
                "--trust",
                "--model", "composer-1.5",
            ]
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "cursor-agent", arguments: launch, kind: "cursor"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "cursor-agent",
                arguments: ["cursor-agent", "agent", "-p", "fix this", "--yolo"],
                kind: "cursor"
            ) == .oneShot
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "cursor-agent",
                arguments: ["cursor-agent", "ls"],
                kind: "cursor"
            ) == .interactive
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["cursor-agent", "ls", "--model", "composer-1.5"],
                launcher: "cursor",
                fallbackKind: "cursor"
            ) == ["cursor-agent"]
        )
    }

    @Test("Gemini 0.51.0 booleans do not consume adjacent flags")
    func geminiCurrentContracts() {
        let launch = [
            "gemini",
            "-s",
            "--debug",
            "-d",
            "--yolo",
            "-y",
            "--skip-trust",
            "--screen-reader",
            "--worktree",
            "--model", "gemini-2.5-pro",
        ]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                launch, launcher: "gemini", fallbackKind: "gemini"
            ) == [
                "gemini",
                "-s",
                "--debug",
                "-d",
                "--yolo",
                "-y",
                "--skip-trust",
                "--screen-reader",
                "--model", "gemini-2.5-pro",
            ]
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "gemini", arguments: launch, kind: "gemini"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "gemini",
                arguments: ["gemini", "-p", "fix this", "-y", "--screen-reader"],
                kind: "gemini"
            ) == .oneShot
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["gemini", "-w", "scratch", "--model", "gemini-2.5-pro"],
                launcher: "gemini",
                fallbackKind: "gemini"
            ) == ["gemini", "--model", "gemini-2.5-pro"]
        )
        for arguments in [
            ["gemini", "--list-sessions"],
            ["gemini", "--delete-session", "session-1"],
            ["gemini", "--list-extensions"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "gemini", arguments: arguments, kind: "gemini"
                ) == .nonSession,
                "\(arguments)"
            )
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "gemini", fallbackKind: "gemini"
                ) == nil,
                "\(arguments)"
            )
        }
    }

    @Test("Kimi 1.37.0 interactive booleans")
    func kimiCurrentContracts() {
        let launch = [
            "kimi",
            "--verbose",
            "--debug",
            "--thinking",
            "--no-thinking",
            "--plan",
            "--yolo",
            "--yes",
            "--auto-approve",
            "-y",
            "--model", "kimi-for-coding",
            "initial prompt",
        ]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                launch, launcher: "kimi", fallbackKind: "kimi"
            ) == Array(launch.dropLast())
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "kimi", arguments: launch, kind: "kimi"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "kimi",
                arguments: ["kimi", "--print", "fix this", "--auto-approve"],
                kind: "kimi"
            ) == .oneShot
        )
        for selector in ["--session", "--resume", "-S", "-r"] {
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    ["kimi", selector, "--model", "kimi-for-coding"],
                    launcher: "kimi",
                    fallbackKind: "kimi"
                ) == ["kimi", "--model", "kimi-for-coding"],
                Comment(rawValue: selector)
            )
        }
    }

    @Test("Hermes Agent 0.15.1 booleans and utilities")
    func hermesCurrentContracts() {
        let safeFlags = [
            "hermes",
            "--tui",
            "--yolo",
            "--accept-hooks",
            "--pass-session-id",
            "--ignore-user-config",
            "--ignore-rules",
            "--dev",
            "--model", "gpt-5.4",
        ]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                safeFlags, launcher: "hermes-agent", fallbackKind: "hermes-agent"
            ) == safeFlags
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "-w", "--model", "gpt-5.4"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == ["hermes", "--model", "gpt-5.4"]
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "hermes", arguments: safeFlags, kind: "hermes-agent"
            ) == .interactive
        )
        for arguments in [
            ["hermes", "--version"],
            ["hermes", "-V"],
            ["hermes", "skills", "list"],
            ["hermes", "fallback", "list"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "hermes", arguments: arguments, kind: "hermes-agent"
                ) == .nonSession,
                "\(arguments)"
            )
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "hermes-agent", fallbackKind: "hermes-agent"
                ) == nil,
                "\(arguments)"
            )
        }
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "hermes",
                arguments: ["hermes", "acp"],
                kind: "hermes-agent"
            ) == .interactive
        )
        let checkpoints = ["hermes", "chat", "--checkpoints", "--model", "gpt-5.4"]
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "hermes", arguments: checkpoints, kind: "hermes-agent"
            ) == .interactive
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                checkpoints, launcher: "hermes-agent", fallbackKind: "hermes-agent"
            ) == ["hermes", "--checkpoints", "--model", "gpt-5.4"]
        )
    }

    @Test("Current provider root metadata flags always exit")
    func currentProviderRootMetadataFlagsAlwaysExit() {
        let providers: [(executable: String, launcher: String, kind: String, options: [String])] = [
            ("claude", "claude", "claude", ["--help", "-h", "--version", "-v"]),
            ("codex", "codex", "codex", ["--help", "-h", "--version", "-V"]),
            ("grok", "grok", "grok", ["--help", "-h", "--version", "-v"]),
            ("pi", "pi", "pi", ["--help", "-h", "--version", "-v"]),
            ("omp", "omp", "omp", ["--help", "-h", "--version", "-v"]),
            ("campfire", "campfire", "campfire", ["--help", "-h", "--version", "-v"]),
            ("opencode", "opencode", "opencode", ["--help", "-h", "--version", "-v"]),
            ("cursor-agent", "cursor", "cursor", ["--help", "-h", "--version", "-v"]),
            ("amp", "amp", "amp", ["--help", "-h", "--version", "-V", "-v"]),
            ("kimi", "kimi", "kimi", ["--help", "-h", "--version", "-V"]),
            ("hermes", "hermes-agent", "hermes-agent", ["--help", "-h", "--version", "-V"]),
            ("gemini", "gemini", "gemini", ["--help", "-h", "--version", "-v"]),
            ("kiro-cli", "kiro", "kiro", ["--help", "-h", "--version", "-V"]),
            ("copilot", "copilot", "copilot", ["--help", "-h", "--version", "-v"]),
            ("droid", "factory", "factory", ["--help", "-h", "--version", "-v"]),
        ]

        for provider in providers {
            for option in provider.options {
                let arguments = [provider.executable, option]
                #expect(
                    AgentLaunchModeClassifier.processMode(
                        processName: provider.executable,
                        arguments: arguments,
                        kind: provider.kind
                    ) == .nonSession,
                    "\(provider.kind) \(option)"
                )
                #expect(
                    AgentLaunchSanitizer.sanitizedLaunchArguments(
                        arguments,
                        launcher: provider.launcher,
                        fallbackKind: provider.kind
                    ) == nil,
                    "\(provider.kind) \(option)"
                )
            }
        }

        for arguments in [
            ["codex", "initial prompt", "--help"],
            ["codex", "-i", "/tmp/a.png", "/tmp/b.png", "--help"],
            ["codex", "resume", "019dad34-d218-7943-b81a-eddac5c87951", "--version"],
            ["claude", "initial prompt", "--version"],
        ] {
            let kind = arguments[0]
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: kind,
                    arguments: arguments,
                    kind: kind
                ) == .nonSession,
                "late metadata \(arguments)"
            )
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments,
                    launcher: kind,
                    fallbackKind: kind
                ) == nil,
                "late metadata \(arguments)"
            )
        }
    }

    @Test("Codex 0.144.3 interactive booleans preserve adjacent options")
    func codexCurrentInteractiveBooleans() {
        for option in [
            "--strict-config",
            "--oss",
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-bypass-hook-trust",
            "--search",
            "--no-alt-screen",
        ] {
            let arguments = ["codex", option, "--model", "gpt-5.4"]
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "codex", fallbackKind: "codex"
                ) == arguments,
                Comment(rawValue: option)
            )
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "codex", arguments: arguments, kind: "codex"
                ) == .interactive,
                Comment(rawValue: option)
            )
        }
    }

    @Test("Pi 0.80.6 interactive booleans preserve adjacent options")
    func piCurrentInteractiveBooleans() {
        for option in [
            "--no-tools", "-nt",
            "--no-builtin-tools", "-nbt",
            "--no-extensions", "-ne",
            "--no-skills", "-ns",
            "--no-prompt-templates", "-np",
            "--no-themes",
            "--no-context-files", "-nc",
            "--approve", "-a",
            "--no-approve", "-na",
            "--offline",
        ] {
            let arguments = ["pi", option, "--model", "anthropic/claude-sonnet"]
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "pi", fallbackKind: "pi"
                ) == arguments,
                Comment(rawValue: option)
            )
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "pi", arguments: arguments, kind: "pi"
                ) == .interactive,
                Comment(rawValue: option)
            )
        }

        for provider in ["pi", "omp", "campfire"] {
            for selector in ["--resume", "-r"] {
                #expect(
                    AgentLaunchSanitizer.sanitizedLaunchArguments(
                        [provider, selector, "--model", "anthropic/claude-sonnet"],
                        launcher: provider,
                        fallbackKind: provider
                    ) == [provider, "--model", "anthropic/claude-sonnet"],
                    "\(provider) \(selector) picker"
                )
            }
        }

        for provider in ["pi", "campfire"] {
            let arguments = [provider, "-xt", "read,bash", "--model", "anthropic/claude-sonnet"]
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: provider, fallbackKind: provider
                ) == arguments,
                "\(provider) -xt"
            )
        }
    }

    @Test("Grok 0.2.103 interactive booleans preserve adjacent options")
    func grokCurrentInteractiveBooleans() {
        for option in [
            "--always-approve",
            "--debug",
            "--disable-web-search",
            "--experimental-memory",
            "--fullscreen",
            "--minimal",
            "--no-alt-screen",
            "--no-memory",
            "--no-plan",
            "--no-subagents",
            "--oauth",
            "--verbatim",
        ] {
            let arguments = ["grok", option, "--model", "grok-code-fast-1"]
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "grok", fallbackKind: "grok"
                ) == arguments,
                Comment(rawValue: option)
            )
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "grok", arguments: arguments, kind: "grok"
                ) == .interactive,
                Comment(rawValue: option)
            )
        }

        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["grok", "-s", "old-session", "--check", "--model", "grok-code-fast-1"],
                launcher: "grok",
                fallbackKind: "grok"
            ) == ["grok", "--check", "--model", "grok-code-fast-1"]
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "grok",
                arguments: ["grok", "--check", "--model", "grok-code-fast-1"],
                kind: "grok"
            ) == .interactive
        )
    }

    @Test("OpenCode 1.18.3 root options preserve exact widths")
    func openCodeCurrentRootOptions() {
        for option in ["--print-logs", "--pure", "--mdns", "--auto", "--mini", "--no-replay"] {
            let arguments = ["opencode", option, "--model", "openai/gpt-5.4"]
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "opencode", fallbackKind: "opencode"
                ) == arguments,
                Comment(rawValue: option)
            )
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "opencode", arguments: arguments, kind: "opencode"
                ) == .interactive,
                Comment(rawValue: option)
            )
        }

        let replayLimit = ["opencode", "--replay-limit", "40", "--model", "openai/gpt-5.4"]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                replayLimit, launcher: "opencode", fallbackKind: "opencode"
            ) == replayLimit
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "opencode", arguments: replayLimit, kind: "opencode"
            ) == .interactive
        )
    }

    @Test("Long-lived protocol entrypoints distinguish commands that exit")
    func longLivedProtocolEntrypointsDistinguishCommandsThatExit() {
        for arguments in [
            ["codex", "app-server"],
            ["codex", "app-server", "proxy"],
            ["codex", "mcp-server"],
            ["codex", "exec-server"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "codex", arguments: arguments, kind: "codex"
                ) == .interactive,
                "\(arguments)"
            )
        }
        for arguments in [
            ["codex", "app-server", "daemon", "start"],
            ["codex", "app-server", "generate-ts"],
            ["codex", "app-server", "generate-json-schema"],
            ["codex", "mcp-server", "--help"],
            ["codex", "exec-server", "--help"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "codex", arguments: arguments, kind: "codex"
                ) == .nonSession,
                "\(arguments)"
            )
        }

        for arguments in [
            ["hermes", "acp"],
            ["hermes", "acp", "--accept-hooks"],
            ["hermes", "gateway", "run"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "hermes", arguments: arguments, kind: "hermes-agent"
                ) == .interactive,
                "\(arguments)"
            )
        }
        for arguments in [
            ["hermes", "acp", "--check"],
            ["hermes", "acp", "--help"],
            ["hermes", "acp", "--setup"],
            ["hermes", "acp", "--setup-browser"],
            ["hermes", "acp", "--version"],
            ["hermes", "gateway"],
            ["hermes", "gateway", "run", "--help"],
            ["hermes", "gateway", "status"],
            ["hermes", "gateway", "start"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "hermes", arguments: arguments, kind: "hermes-agent"
                ) == .nonSession,
                "\(arguments)"
            )
        }

        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "grok",
                arguments: ["grok", "agent", "--agent-profile", "/tmp/profile.json", "stdio"],
                kind: "grok"
            ) == .interactive
        )
        let protocolHelpCases: [(processName: String, kind: String, arguments: [String])] = [
            ("claude", "claude", ["claude", "--input-format", "stream-json", "--help"]),
            ("pi", "pi", ["pi", "--mode", "rpc", "--help"]),
            ("omp", "omp", ["omp", "--mode", "rpc-ui", "--help"]),
            ("campfire", "campfire", ["campfire", "--mode", "rpc", "--help"]),
            ("droid", "factory", [
                "droid", "exec", "--input-format", "stream-jsonrpc",
                "--output-format", "stream-jsonrpc", "--help",
            ]),
            ("kimi", "kimi", ["kimi", "--acp", "--help"]),
            ("grok", "grok", ["grok", "agent", "stdio", "--help"]),
            ("opencode", "opencode", ["opencode", "serve", "--help"]),
            ("qodercli", "qoder", ["qodercli", "--acp", "--help"]),
        ]
        for testCase in protocolHelpCases {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: testCase.processName,
                    arguments: testCase.arguments,
                    kind: testCase.kind
                ) == .nonSession,
                "\(testCase.arguments)"
            )
        }
    }

    @Test("Claude 2.1.214 no-persistence is terminal only with print mode")
    func claudeNoPersistenceLifetimeContract() {
        let oneShot = ["claude", "-p", "fix this", "--no-session-persistence"]
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "claude", arguments: oneShot, kind: "claude"
            ) == .oneShot
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                oneShot, launcher: "claude", fallbackKind: "claude"
            ) == nil
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "claude",
                arguments: ["claude", "--no-session-persistence"],
                kind: "claude"
            ) == .unknown
        )
    }

    @Test("Amp 0.0.1784376855 command and runner lifetimes")
    func ampCurrentContracts() {
        for arguments in [
            ["amp", "--no-tui", "--runner-id", "cmux-dogfood"],
            ["amp", "-x", "first", "--stream-json", "--stream-json-input"],
            ["amp", "last"],
            ["amp", "l"],
            ["amp", "threads", "continue", "T-123"],
            ["amp", "t", "c", "T-123"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "amp", arguments: arguments, kind: "amp"
                ) == .interactive,
                "\(arguments)"
            )
        }
        for arguments in [
            ["amp", "threads", "new"],
            ["amp", "threads", "list"],
            ["amp", "config", "edit"],
            ["amp", "orb", "service", "status"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "amp", arguments: arguments, kind: "amp"
                ) == .nonSession,
                "\(arguments)"
            )
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "amp", fallbackKind: "amp"
                ) == nil,
                "\(arguments)"
            )
        }
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "amp",
                arguments: ["amp", "--stream-json-input"],
                kind: "amp"
            ) == .unknown
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["amp", "threads", "continue", "OLD", "--mode", "high"],
                launcher: "amp",
                fallbackKind: "amp"
            ) == ["amp", "--mode", "high"]
        )
    }

    @Test("Pi 0.80.6 and OMP 16.2.11 utility modes exit")
    func piAndOMPUtilityContracts() {
        for arguments in [
            ["pi", "--export", "/tmp/session.jsonl"],
            ["pi", "--list-models"],
            ["pi", "--list-models", "sonnet"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "pi", arguments: arguments, kind: "pi"
                ) == .nonSession,
                "\(arguments)"
            )
        }
        for arguments in [
            ["omp", "--alias", "omp-work"],
            ["omp", "--export", "/tmp/session.jsonl"],
            ["omp", "agents"],
            ["omp", "bench"],
            ["omp", "models"],
            ["omp", "worktree"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "omp", arguments: arguments, kind: "omp"
                ) == .nonSession,
                "\(arguments)"
            )
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "omp", fallbackKind: "omp"
                ) == nil,
                "\(arguments)"
            )
        }
        for command in ["acp", "auth-gateway", "join", "shell"] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "omp", arguments: ["omp", command], kind: "omp"
                ) == .interactive,
                Comment(rawValue: command)
            )
        }
    }

    @Test("Cursor 2026.07.16 list-models exits")
    func cursorListModelsContract() {
        let arguments = ["cursor-agent", "--list-models"]
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "cursor-agent", arguments: arguments, kind: "cursor"
            ) == .nonSession
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments, launcher: "cursor", fallbackKind: "cursor"
            ) == nil
        )
    }

    @Test("Factory documented root and exec option widths")
    func factoryDocumentedContracts() {
        let interactive = [
            "droid", "--model", "claude-sonnet-4-6", "--auto", "medium",
            "--enabled-tools", "ApplyPatch,Bash", "--worktree", "feature-a",
        ]
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "droid", arguments: interactive, kind: "factory"
            ) == .interactive
        )
        let oneShot = [
            "droid", "exec", "--file", "mission.md", "--model", "claude-sonnet-4-6",
            "--reasoning-effort=high", "--use-spec", "--spec-model", "claude-opus-4-7",
            "--worker-model", "claude-sonnet-4-6", "--validator-model", "claude-opus-4-7",
        ]
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "droid", arguments: oneShot, kind: "factory"
            ) == .oneShot
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "droid",
                arguments: ["droid", "exec", "--list-tools"],
                kind: "factory"
            ) == .nonSession
        )
    }

    @Test("Documented absent-provider contracts fail closed or preserve exact widths")
    func documentedAbsentProviderContracts() {
        let cases: [(process: String, kind: String, arguments: [String], mode: AgentProcessLaunchMode)] = [
            ("kiro-cli", "kiro", ["kiro-cli", "chat", "--list-models"], .nonSession),
            ("kiro-cli", "kiro", ["kiro-cli", "chat", "--no-interactive", "--effort", "high", "--trust-all-tools", "fix"], .oneShot),
            ("agy", "antigravity", ["agy", "models"], .nonSession),
            ("acli", "rovodev", ["acli", "rovodev", "serve", "8080"], .interactive),
            ("acli", "rovodev", ["acli", "rovodev", "run", "--worktree", "--web", "--yolo"], .interactive),
            ("codebuddy", "codebuddy", ["codebuddy", "--bg", "fix"], .nonSession),
            ("codebuddy", "codebuddy", ["codebuddy", "--serve", "--port", "8080"], .interactive),
            ("codebuddy", "codebuddy", ["codebuddy", "--prewarm", "--prewarm-id", "pool-1"], .interactive),
            ("qodercli", "qoder", ["qodercli", "--remote", "fix this"], .oneShot),
        ]
        for testCase in cases {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: testCase.process,
                    arguments: testCase.arguments,
                    kind: testCase.kind
                ) == testCase.mode,
                "\(testCase.arguments)"
            )
        }

        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["copilot", "--session-id", "OLD", "--attachment", "prompt.png", "-C", "/tmp/repo", "--model", "gpt-5.4"],
                launcher: "copilot",
                fallbackKind: "copilot"
            ) == ["copilot", "-C", "/tmp/repo", "--model", "gpt-5.4"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["qodercli", "--worktree", "feature-a", "--max-turns", "10", "--yolo", "--model", "qoder"],
                launcher: "qoder",
                fallbackKind: "qoder"
            ) == ["qodercli", "--max-turns", "10", "--yolo", "--model", "qoder"]
        )
    }

    @Test("Interactive subcommands fail closed on unknown options")
    func interactiveSubcommandsFailClosedOnUnknownOptions() {
        let cases: [(process: String, kind: String, arguments: [String])] = [
            ("codex", "codex", ["codex", "resume", "session-1", "--cmux-unknown"]),
            ("codex", "codex", ["codex", "fork", "session-1", "--cmux-unknown=value"]),
            ("opencode", "opencode", ["opencode", "attach", "http://127.0.0.1:4096", "--cmux-unknown"]),
            ("opencode", "opencode", ["opencode", "pr", "123", "--cmux-unknown=value"]),
            ("kiro-cli", "kiro", ["kiro-cli", "chat", "--cmux-unknown"]),
        ]

        for testCase in cases {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: testCase.process,
                    arguments: testCase.arguments,
                    kind: testCase.kind
                ) == .unknown,
                "\(testCase.arguments)"
            )
        }
    }

    @Test("Current interactive subcommand options remain recognized")
    func currentInteractiveSubcommandOptionsRemainRecognized() {
        let cases: [(process: String, kind: String, arguments: [String])] = [
            ("codex", "codex", ["codex", "resume", "--include-non-interactive", "--last"]),
            ("codex", "codex", ["codex", "fork", "--all", "--last"]),
            ("opencode", "opencode", [
                "opencode", "attach", "http://127.0.0.1:4096",
                "--dir", "/tmp/project", "--username", "cmux", "--password", "secret",
            ]),
            ("opencode", "opencode", ["opencode", "pr", "123", "--pure"]),
            ("kiro-cli", "kiro", ["kiro-cli", "chat", "--effort", "high", "--trust-all-tools"]),
        ]

        for testCase in cases {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: testCase.process,
                    arguments: testCase.arguments,
                    kind: testCase.kind
                ) == .interactive,
                "\(testCase.arguments)"
            )
        }
    }

    @Test("One-shot output modifiers retain terminal lifetime")
    func oneShotOutputModifiersRetainTerminalLifetime() {
        let cases: [(process: String, kind: String, arguments: [String])] = [
            ("pi", "pi", ["pi", "--print", "--no-session", "fix this"]),
            ("omp", "omp", ["omp", "-p", "--no-session", "fix this"]),
            ("campfire", "campfire", ["campfire", "-p", "--no-session", "fix this"]),
            ("kimi", "kimi", ["kimi", "--print", "--prompt", "fix this"]),
            ("kimi", "kimi", ["kimi", "--quiet", "--command", "fix this"]),
        ]

        for testCase in cases {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: testCase.process,
                    arguments: testCase.arguments,
                    kind: testCase.kind
                ) == .oneShot,
                "\(testCase.arguments)"
            )
        }
    }

    @Test("Claude forwarding output remains one-shot only in its documented print mode")
    func claudeForwardingOutputContract() {
        let oneShot = [
            "claude", "--print", "--output-format", "stream-json",
            "--forward-subagent-text", "fix this",
        ]
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "claude", arguments: oneShot, kind: "claude"
            ) == .oneShot
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                oneShot, launcher: "claude", fallbackKind: "claude"
            ) == nil
        )

        for invalid in [
            ["claude", "--forward-subagent-text", "fix this"],
            ["claude", "--print", "--forward-subagent-text", "fix this"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "claude", arguments: invalid, kind: "claude"
                ) == .unknown,
                "\(invalid)"
            )
        }
    }

    @Test("Gemini ACP overrides terminal-looking prompt flags")
    func geminiACPProtocolLifetime() {
        for arguments in [
            ["gemini", "--acp", "--prompt", "ignored by ACP"],
            ["gemini", "--experimental-acp", "-p", "ignored by ACP"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "gemini", arguments: arguments, kind: "gemini"
                ) == .interactive,
                "\(arguments)"
            )
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "gemini", fallbackKind: "gemini"
                ) == nil,
                "\(arguments)"
            )
        }
    }

    @Test("Gemini utility command aliases never restore as sessions")
    func geminiUtilityAliasesAreNonSession() {
        for command in ["extension", "skill", "hook"] {
            let arguments = ["gemini", command, "list"]
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "gemini", arguments: arguments, kind: "gemini"
                ) == .nonSession,
                Comment(rawValue: command)
            )
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "gemini", fallbackKind: "gemini"
                ) == nil,
                Comment(rawValue: command)
            )
        }
    }

    @Test("Codex resume-only picker option is rejected by fork")
    func codexForkRejectsResumeOnlyPickerOption() {
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "codex",
                arguments: ["codex", "fork", "--include-non-interactive", "--last"],
                kind: "codex"
            ) == .unknown
        )
    }

    @Test("Cursor plan and worker modes match the current command grammar")
    func cursorPlanAndWorkerModes() {
        let plan = ["cursor-agent", "--plan", "inspect this"]
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "cursor-agent", arguments: plan, kind: "cursor"
            ) == .interactive
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                plan, launcher: "cursor", fallbackKind: "cursor"
            ) == ["cursor-agent", "--plan"]
        )

        for arguments in [
            ["cursor-agent", "worker", "start"],
            ["cursor-agent", "worker", "--worker-dir", "/tmp/cmux-worker", "start"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "cursor-agent", arguments: arguments, kind: "cursor"
                ) == .interactive,
                "\(arguments)"
            )
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "cursor", fallbackKind: "cursor"
                ) == nil,
                "\(arguments)"
            )
        }

        for arguments in [
            ["cursor-agent", "worker"],
            ["cursor-agent", "worker", "debug"],
        ] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "cursor-agent", arguments: arguments, kind: "cursor"
                ) == .nonSession,
                "\(arguments)"
            )
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments, launcher: "cursor", fallbackKind: "cursor"
                ) == nil,
                "\(arguments)"
            )
        }
    }

    @Test("Protocol-looking prompt tokens do not extend one-shot lifetime")
    func protocolLookingPromptTokensRemainOneShot() {
        let cases: [(process: String, kind: String, arguments: [String])] = [
            ("claude", "claude", [
                "claude", "--print", "--", "--input-format", "stream-json",
            ]),
            ("pi", "pi", ["pi", "--print", "--", "--mode", "rpc"]),
            ("omp", "omp", ["omp", "--print", "--", "--mode=rpc-ui"]),
            ("campfire", "campfire", [
                "campfire", "--print", "--", "--mode", "rpc",
            ]),
            ("gemini", "gemini", [
                "gemini", "--prompt", "fix this", "--", "--acp",
            ]),
            ("kimi", "kimi", ["kimi", "--print", "--", "--acp"]),
            ("codebuddy", "codebuddy", [
                "codebuddy", "--print", "--", "--serve",
            ]),
            ("qodercli", "qoder", ["qodercli", "--print", "--", "--acp"]),
            ("amp", "amp", ["amp", "--execute", "--", "--no-tui"]),
        ]

        for testCase in cases {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: testCase.process,
                    arguments: testCase.arguments,
                    kind: testCase.kind
                ) == .oneShot,
                "\(testCase.arguments)"
            )
        }
    }
}
