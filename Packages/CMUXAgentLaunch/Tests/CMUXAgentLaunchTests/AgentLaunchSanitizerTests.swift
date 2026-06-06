import CMUXAgentLaunch
import Testing

@Suite("AgentLaunchSanitizer")
struct AgentLaunchSanitizerTests {
    @Test("Preserves Codex Teams launcher while dropping prompt")
    func preservesCodexTeamsLauncher() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "codex-teams",
                    "--model",
                    "gpt-5.4",
                    "--sandbox",
                    "danger-full-access",
                    "--remote",
                    "ws://127.0.0.1:1",
                    "--remote-auth-token-env=OLD_CODEX_TOKEN",
                    "--ask-for-approval",
                    "never",
                    "initial prompt should not replay",
                ],
                launcher: "codexTeams",
                fallbackKind: "codex"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "codex-teams",
                "--model",
                "gpt-5.4",
                "--sandbox",
                "danger-full-access",
                "--ask-for-approval",
                "never",
            ]
        )
    }

    @Test("Preserves direct Codex fork launch context")
    func preservesDirectCodexForkLaunchContext() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "codex",
                    "--model",
                    "gpt-5.4",
                    "fork",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                    "--sandbox",
                    "danger-full-access",
                    "--remote",
                    "ws://127.0.0.1:1",
                    "--remote-auth-token-env=OLD_CODEX_TOKEN",
                    "prompt should not replay",
                ],
                launcher: "codex",
                fallbackKind: "codex"
            ) == [
                "codex",
                "--model",
                "gpt-5.4",
                "--sandbox",
                "danger-full-access",
            ]
        )
    }

    @Test("Detects Codex fork after startup image options")
    func detectsCodexForkAfterStartupImageOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "codex",
                    "--image",
                    "/tmp/screenshot.png",
                    "fork",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                    "--sandbox",
                    "danger-full-access",
                    "--remote",
                    "ws://127.0.0.1:1",
                    "--remote-auth-token-env=OLD_CODEX_TOKEN",
                    "prompt should not replay",
                ],
                launcher: "codex",
                fallbackKind: "codex"
            ) == [
                "codex",
                "--sandbox",
                "danger-full-access",
            ]
        )
    }

    @Test("Drops Codex startup images and keeps following flags")
    func dropsCodexStartupImagesAndKeepsFollowingFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "codex",
                    "--image",
                    "fork",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                    "--model",
                    "gpt-5.4",
                ],
                launcher: "codex",
                fallbackKind: "codex"
            ) == [
                "codex",
                "--model",
                "gpt-5.4",
            ]
        )
    }

    @Test("Drops Codex restored image placeholder and prompt")
    func dropsCodexRestoredImagePlaceholderAndPrompt() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "codex",
                    "--yolo",
                    "--image",
                    "[Image #1]",
                    "[Image #1] cmd clicking this should open the crash file in finder",
                    "--model",
                    "gpt-5.4",
                ],
                launcher: "codex",
                fallbackKind: "codex"
            ) == [
                "codex",
                "--yolo",
                "--model",
                "gpt-5.4",
            ]
        )
    }

    @Test("Drops Claude startup files")
    func dropsClaudeStartupFiles() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--file",
                    "file_123:screenshot.png",
                    "initial prompt should not replay",
                    "--model",
                    "sonnet",
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--model",
                "sonnet",
            ]
        )
    }

    @Test("Drops OpenCode startup files before preserving cwd")
    func dropsOpenCodeStartupFilesBeforePreservingCwd() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "opencode",
                    "--file",
                    "/tmp/screenshot.png",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "/tmp/worktree",
                    "initial prompt should not replay",
                ],
                launcher: "opencode",
                fallbackKind: "opencode"
            ) == [
                "opencode",
                "--model",
                "anthropic/claude-sonnet-4-6",
                "/tmp/worktree",
            ]
        )
    }

    @Test("Drops OpenCode startup file when it appears before cwd")
    func dropsOpenCodeStartupFileBeforeCwd() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "opencode",
                    "--file",
                    "/tmp/screenshot.png",
                    "/tmp/worktree",
                    "initial prompt should not replay",
                ],
                launcher: "opencode",
                fallbackKind: "opencode"
            ) == [
                "opencode",
                "/tmp/worktree",
            ]
        )
    }

    @Test("Drops repeated OpenCode startup files before preserving cwd")
    func dropsRepeatedOpenCodeStartupFilesBeforeCwd() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "opencode",
                    "--file",
                    "/tmp/screenshot.png",
                    "-f",
                    "/tmp/transcript.txt",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "/tmp/worktree",
                    "initial prompt should not replay",
                ],
                launcher: "opencode",
                fallbackKind: "opencode"
            ) == [
                "opencode",
                "--model",
                "anthropic/claude-sonnet-4-6",
                "/tmp/worktree",
            ]
        )
    }

    @Test("Preserves generated Codex fork launch context")
    func preservesGeneratedCodexForkLaunchContext() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "codex",
                    "fork",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    "/tmp/extra repo",
                    "--sandbox",
                    "danger-full-access",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                ],
                launcher: "codex",
                fallbackKind: "codex"
            ) == [
                "codex",
                "--model",
                "gpt-5.4",
                "--add-dir",
                "/tmp/extra repo",
                "--sandbox",
                "danger-full-access",
            ]
        )
    }

    @Test("Keeps Codex variadic values named fork")
    func keepsCodexVariadicValuesNamedFork() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "codex",
                    "--add-dir",
                    "fork",
                    "--model",
                    "gpt-5.4",
                ],
                launcher: "codex",
                fallbackKind: "codex"
            ) == [
                "codex",
                "--add-dir",
                "fork",
                "--model",
                "gpt-5.4",
            ]
        )
    }

    @Test("Preserves Codex Teams fork launch context")
    func preservesCodexTeamsForkLaunchContext() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "codex-teams",
                    "--model",
                    "gpt-5.4",
                    "fork",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                    "--ask-for-approval",
                    "never",
                    "--remote",
                    "ws://127.0.0.1:1",
                    "--remote-auth-token-env=OLD_CODEX_TOKEN",
                    "prompt should not replay",
                ],
                launcher: "codexTeams",
                fallbackKind: "codex"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "codex-teams",
                "--model",
                "gpt-5.4",
                "--ask-for-approval",
                "never",
            ]
        )
    }

    @Test("Drops OpenCode fork prefix option while preserving fork context")
    func dropsOpenCodeForkPrefixOptionWhilePreservingForkContext() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "opencode",
                    "--session",
                    "parent-session",
                    "--fork=parent-session",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "/tmp/opencode repo",
                ],
                launcher: "opencode",
                fallbackKind: "opencode"
            ) == [
                "opencode",
                "--model",
                "anthropic/claude-sonnet-4-6",
                "/tmp/opencode repo",
            ]
        )
    }

    @Test("Consumes terminal optional values")
    func consumesTerminalOptionalValues() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["copilot", "--model", "gpt-5.4", "--allow-tool", "Read"],
                launcher: "copilot",
                fallbackKind: "copilot"
            ) == ["copilot", "--model", "gpt-5.4", "--allow-tool", "Read"]
        )
    }

    @Test("Drops Gemini worktree value before preserving later options")
    func dropsGeminiWorktreeValueBeforePreservingLaterOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["gemini", "--worktree", "/tmp/repo", "--model", "gemini-2.5-pro"],
                launcher: "gemini",
                fallbackKind: "gemini"
            ) == ["gemini", "--model", "gemini-2.5-pro"]
        )
    }

    @Test("Drops Antigravity conversation selectors without replaying prompts")
    func dropsAntigravityConversationSelectorsWithoutReplayingPrompts() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "agy",
                    "--conversation",
                    "old-conversation",
                    "--sandbox",
                    "danger-full-access",
                    "--add-dir",
                    "/tmp/extra repo",
                    "initial prompt should not replay",
                ],
                launcher: "antigravity",
                fallbackKind: "antigravity"
            ) == [
                "agy",
                "--sandbox",
                "danger-full-access",
                "--add-dir",
                "/tmp/extra repo",
            ]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["agy", "--conversation=old-conversation", "--log-file", "/tmp/agy.log"],
                launcher: "antigravity",
                fallbackKind: "antigravity"
            ) == ["agy", "--log-file", "/tmp/agy.log"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["agy", "--conversation", "--sandbox", "danger-full-access"],
                launcher: "antigravity",
                fallbackKind: "antigravity"
            ) == ["agy"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["agy", "--continue", "old-conversation", "--sandbox", "danger-full-access"],
                launcher: "antigravity",
                fallbackKind: "antigravity"
            ) == ["agy", "--sandbox", "danger-full-access"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["agy", "-c", "--sandbox", "danger-full-access"],
                launcher: "antigravity",
                fallbackKind: "antigravity"
            ) == ["agy", "--sandbox", "danger-full-access"]
        )
    }

    @Test("Drops OMP session selectors without replaying prompts")
    func dropsOmpSessionSelectorsWithoutReplayingPrompts() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "omp",
                    "-r",
                    "old-session",
                    "--model",
                    "anthropic/claude-sonnet-4-5",
                    "initial prompt should not replay",
                ],
                launcher: "omp",
                fallbackKind: "omp"
            ) == [
                "omp",
                "--model",
                "anthropic/claude-sonnet-4-5",
            ]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["omp", "--resume=old-session", "--theme", "dark"],
                launcher: "omp",
                fallbackKind: "omp"
            ) == ["omp", "--theme", "dark"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["omp", "--session", "old-session", "--model", "anthropic/claude-sonnet-4-5"],
                launcher: "omp",
                fallbackKind: "omp"
            ) == ["omp", "--model", "anthropic/claude-sonnet-4-5"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["omp", "--session=old-session", "--theme", "dark"],
                launcher: "omp",
                fallbackKind: "omp"
            ) == ["omp", "--theme", "dark"]
        )
    }

    @Test("Rejects noninteractive Antigravity launches")
    func rejectsNoninteractiveAntigravityLaunches() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["agy", "--print", "--prompt", "summarize"],
                launcher: "antigravity",
                fallbackKind: "antigravity"
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["agy", "--prompt", "summarize"],
                launcher: "antigravity",
                fallbackKind: "antigravity"
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["agy", "-i", "--prompt", "summarize"],
                launcher: "antigravity",
                fallbackKind: "antigravity"
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["agy", "-p", "summarize"],
                launcher: "antigravity",
                fallbackKind: "antigravity"
            ) == nil
        )
    }

    @Test("Drops Grok optional selectors without swallowing later options")
    func dropsGrokOptionalSelectorsWithoutSwallowingLaterOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["grok", "--resume", "--model", "grok-4", "--worktree", "--permission-mode", "auto"],
                launcher: "grok",
                fallbackKind: "grok"
            ) == ["grok", "--model", "grok-4", "--permission-mode", "auto"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["grok", "-r", "old-session", "-w", "scratch", "--sandbox", "danger-full-access"],
                launcher: "grok",
                fallbackKind: "grok"
            ) == ["grok", "--sandbox", "danger-full-access"]
        )
    }

    @Test("Preserves Cursor options after resume subcommand")
    func preservesCursorOptionsAfterResumeSubcommand() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["cursor-agent", "resume", "chat-123", "--model", "gpt-5.4", "--sandbox", "enabled"],
                launcher: "cursor",
                fallbackKind: "cursor"
            ) == ["cursor-agent", "--model", "gpt-5.4", "--sandbox", "enabled"]
        )
    }

    @Test("Drops Pi session selectors and prompt while preserving configuration")
    func dropsPiSessionSelectorsAndPrompt() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "pi", "--session", "old-session", "--model", "anthropic/claude-sonnet-4-5",
                    "--thinking", "high", "--api-key", "secret", "implement this",
                ],
                launcher: "pi",
                fallbackKind: "pi"
            ) == ["pi", "--model", "anthropic/claude-sonnet-4-5", "--thinking", "high"]
        )
    }

    @Test("Preserves repeated Pi extension and skill flags without replaying prompt")
    func preservesRepeatedPiExtensionAndSkillFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "pi", "--extension", "a.ts", "--extension", "b.ts",
                    "--skill", "review", "--skill", "swift", "initial prompt",
                ],
                launcher: "pi",
                fallbackKind: "pi"
            ) == [
                "pi", "--extension", "a.ts", "--extension", "b.ts",
                "--skill", "review", "--skill", "swift",
            ]
        )
    }

    @Test("Rejects noninteractive Pi launches")
    func rejectsNoninteractivePiLaunches() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["pi", "--print", "summarize"],
                launcher: "pi",
                fallbackKind: "pi"
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["pi", "--prompt", "summarize"],
                launcher: "pi",
                fallbackKind: "pi"
            ) == nil
        )
    }

    @Test("Preserves Hermes inherited flags without replaying startup-only input")
    func preservesHermesInheritedFlagsWithoutReplayingStartupOnlyInput() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "hermes",
                    "--profile",
                    "work",
                    "--tui",
                    "--skills",
                    "github-auth",
                    "-s",
                    "hermes-agent-dev",
                    "--api-key",
                    "secret",
                    "--image",
                    "/tmp/cat.png",
                    "--worktree",
                    "--resume",
                    "old-session",
                    "--source",
                    "cli",
                    "initial prompt should not replay",
                ],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == [
                "hermes",
                "--profile",
                "work",
                "--tui",
                "--skills",
                "github-auth",
                "-s",
                "hermes-agent-dev",
            ]
        )
    }

    @Test("Drops Hermes worktree value before preserving later options")
    func dropsHermesWorktreeValueBeforePreservingLaterOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "--worktree", "/tmp/repo", "--model", "gpt-5.4"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == ["hermes", "--model", "gpt-5.4"]
        )
    }

    @Test("Allows only Hermes chat or default session launch")
    func allowsOnlyHermesChatOrDefaultSessionLaunch() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "chat", "--tui", "--model", "gpt-5.4", "initial prompt"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == ["hermes", "--tui", "--model", "gpt-5.4"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "fallback", "list"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "slack", "send"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == nil
        )
    }

    @Test("Treats Hermes skills as single value options")
    func treatsHermesSkillsAsSingleValueOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "--skills", "skill1", "skill2", "--model", "gpt-5.4"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == ["hermes", "--skills", "skill1"]
        )
    }

    @Test("Preserves explicit Hermes provider")
    func preservesExplicitHermesProvider() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "--provider", "anthropic", "--model", "anthropic/claude-sonnet-4.6"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == ["hermes", "--provider", "anthropic", "--model", "anthropic/claude-sonnet-4.6"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "--provider=anthropic", "--model", "anthropic/claude-sonnet-4.6"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == ["hermes", "--provider=anthropic", "--model", "anthropic/claude-sonnet-4.6"]
        )
    }

    @Test("Rewrites stale Hermes Codex provider")
    func rewritesStaleHermesCodexProvider() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "--provider", "openai-codex", "--model", "gpt-5.5"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == ["hermes", "--provider", "custom", "--model", "gpt-5.5"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "--provider=openai-codex", "--model", "gpt-5.5"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == ["hermes", "--provider=custom", "--model", "gpt-5.5"]
        )
    }

    @Test("Drops Amp --label and its value while preserving later options")
    func dropsAmpLabelValueAndPreservesLaterOptions() {
        // --label takes a value. If --label isn't in valueOptions, the
        // sanitizer drops only `--label` and `foo` slips through as a
        // positional, breaking the resumed launch.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["amp", "--label", "foo", "--mode", "geppetto"],
                launcher: "amp",
                fallbackKind: "amp"
            ) == ["amp", "--mode", "geppetto"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["amp", "-l", "bar", "--effort", "high"],
                launcher: "amp",
                fallbackKind: "amp"
            ) == ["amp", "--effort", "high"]
        )
    }

    @Test("Rejects non-restorable Amp launches and strips resume preamble")
    func rejectsNonRestorableAmpLaunchesAndStripsResumePreamble() {
        // --execute / --print / -x are non-interactive runs; not restorable.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["amp", "--execute", "do this", "--mode", "geppetto"],
                launcher: "amp",
                fallbackKind: "amp"
            ) == nil
        )
        // A previously-resumed launch should have its `threads continue <id>`
        // preamble stripped so a re-resume doesn't re-prepend it.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["amp", "threads", "continue", "T-old-id", "--mode", "geppetto"],
                launcher: "amp",
                fallbackKind: "amp"
            ) == ["amp", "--mode", "geppetto"]
        )
    }

    @Test("Removes cwd options that duplicate the saved working directory")
    func removesSavedWorkingDirectoryOptions() {
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["codex", "resume", "session", "--cd", "/tmp/project", "--model", "gpt-5.4"],
                workingDirectory: "/tmp/project"
            ) == ["codex", "resume", "session", "--model", "gpt-5.4"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["grok", "-r", "session", "--cwd=/tmp/project", "--model", "grok-4"],
                workingDirectory: "/tmp/project"
            ) == ["grok", "-r", "session", "--model", "grok-4"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["qoder", "--workspace", "/tmp/other", "--cwd", "/tmp/project"],
                workingDirectory: "/tmp/project"
            ) == ["qoder", "--workspace", "/tmp/other"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["qoder", "-w", "/tmp/project", "--model", "best"],
                workingDirectory: "/tmp/project"
            ) == ["qoder", "--model", "best"]
        )
    }
}
