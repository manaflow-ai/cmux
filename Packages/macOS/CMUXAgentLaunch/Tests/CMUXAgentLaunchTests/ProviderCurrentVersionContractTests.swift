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
        for command in ["acp", "gateway"] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "hermes",
                    arguments: ["hermes", command],
                    kind: "hermes-agent"
                ) == .interactive,
                "hermes \(command)"
            )
        }
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
            ["hermes", "acp", "--setup"],
            ["hermes", "acp", "--setup-browser"],
            ["hermes", "acp", "--version"],
            ["hermes", "gateway"],
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
    }
}
