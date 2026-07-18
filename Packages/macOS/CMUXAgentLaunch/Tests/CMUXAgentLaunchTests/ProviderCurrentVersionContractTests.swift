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
            ("kimi", "kimi", "kimi", ["--help", "-h", "--version"]),
            ("hermes", "hermes-agent", "hermes-agent", ["--help", "-h", "--version", "-V"]),
            ("gemini", "gemini", "gemini", ["--help", "-h", "--version"]),
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
}
