import CMUXAgentLaunch
import Testing

@Suite("AgentResumeArgv")
struct AgentResumeArgvTests {
    @Test("Built-in --option style kinds", arguments: [
        ("claude", "claude", ["claude", "--resume", "SID"]),
        ("grok", "grok", ["grok", "-r", "SID"]),
        ("pi", "pi", ["pi", "--session", "SID"]),
        ("omp", "omp", ["omp", "--resume", "SID"]),
        ("campfire", "campfire", ["campfire", "--session", "SID"]),
        ("cursor", "cursor-agent", ["cursor-agent", "--resume", "SID"]),
        ("antigravity", "agy", ["agy", "--conversation", "SID"]),
        ("copilot", "copilot", ["copilot", "--resume", "SID"]),
        ("codebuddy", "codebuddy", ["codebuddy", "--resume", "SID"]),
        ("factory", "droid", ["droid", "--resume", "SID"]),
        ("qoder", "qodercli", ["qodercli", "--resume", "SID"]),
        ("kimi", "kimi", ["kimi", "--session", "SID"]),
    ])
    func builtInWithOptionKinds(kind: String, executable: String, expected: [String]) {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: kind, sessionId: "SID", executablePath: nil, arguments: [executable]
            ) == expected
        )
    }

    @Test("Gemini resumes from its recorded session file")
    func geminiUsesSessionFile() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "gemini",
                sessionId: "5839bed1-0a60-4c05-b6d1-2410d7a3741e",
                executablePath: nil,
                arguments: [
                    "gemini",
                    "--session-file", "/tmp/previous.jsonl",
                    "--model", "gemini-2.5-pro",
                ],
                transcriptPath: "/tmp/session-2026-07-18T04-52-5839bed1.jsonl"
            ) == [
                "gemini", "--session-file", "/tmp/session-2026-07-18T04-52-5839bed1.jsonl",
                "--model", "gemini-2.5-pro",
            ]
        )
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "gemini",
                sessionId: "5839bed1-0a60-4c05-b6d1-2410d7a3741e",
                executablePath: nil,
                arguments: ["gemini"]
            ) == nil
        )
    }

    @Test("Kimi resume removes initial prompts and stale interactive sessions")
    func kimiResumeSanitizesInteractiveArguments() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "kimi",
                sessionId: "SID",
                executablePath: nil,
                arguments: [
                    "kimi",
                    "--session", "OLD",
                    "--model", "kimi-k2",
                    "--yolo",
                    "--prompt", "do not replay this prompt",
                ]
            ) == ["kimi", "--session", "SID", "--model", "kimi-k2", "--yolo"]
        )
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "kimi",
                sessionId: "SID",
                executablePath: nil,
                arguments: [
                    "kimi",
                    "--session", "OLD",
                    "--model", "kimi-k2",
                    "--yolo",
                ]
            ) == ["kimi", "--session", "SID", "--model", "kimi-k2", "--yolo"]
        )
    }

    @Test("Kimi resume drops inline configuration secrets but keeps configuration files")
    func kimiResumeDropsInlineConfiguration() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "kimi",
                sessionId: "SID",
                executablePath: nil,
                arguments: [
                    "kimi",
                    "--config", #"model.api_key = "inline-secret""#,
                    "--mcp-config", #"{"mcpServers":{"private":{"env":{"TOKEN":"inline-secret"}}}}"#,
                    "--config-file", "/tmp/kimi.toml",
                    "--mcp-config-file", "/tmp/mcp.json",
                    "--model", "kimi-k2",
                ]
            ) == [
                "kimi", "--session", "SID",
                "--config-file", "/tmp/kimi.toml",
                "--mcp-config-file", "/tmp/mcp.json",
                "--model", "kimi-k2",
            ]
        )
    }

    @Test("Built-in special-shaped kinds")
    func builtInSpecialShapes() {
        #expect(
            AgentResumeArgv().builtInKind(kind: "codex", sessionId: "SID", executablePath: nil, arguments: ["codex"])
                == ["codex", "resume", "SID", "-c", "check_for_update_on_startup=false"]
        )
        #expect(
            AgentResumeArgv().builtInKind(kind: "amp", sessionId: "SID", executablePath: nil, arguments: ["amp"])
                == ["amp", "threads", "continue", "SID"]
        )
        #expect(
            AgentResumeArgv().builtInKind(kind: "kiro", sessionId: "SID", executablePath: nil, arguments: ["kiro-cli"])
                == ["kiro-cli", "chat", "--resume-id", "SID"]
        )
        #expect(
            AgentResumeArgv().builtInKind(kind: "rovodev", sessionId: "SID", executablePath: nil, arguments: ["acli"])
                == ["acli", "rovodev", "run", "--restore", "SID"]
        )
        #expect(
            AgentResumeArgv().builtInKind(kind: "hermes-agent", sessionId: "SID", executablePath: nil, arguments: ["hermes"])
                == ["hermes", "--resume", "SID"]
        )
        #expect(
            AgentResumeArgv().builtInKind(kind: "opencode", sessionId: "SID", executablePath: nil, arguments: ["opencode"])
                == ["opencode", "--session", "SID"]
        )
        #expect(
            AgentResumeArgv().builtInKind(kind: "not-an-agent", sessionId: "SID", executablePath: nil, arguments: ["x"]) == nil
        )
    }

    @Test("OpenCode resume drops internal TUI settings selector")
    func opencodeResumeDropsInternalTUISettingsSelector() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "opencode",
                sessionId: "SID",
                executablePath: nil,
                arguments: [
                    "opencode",
                    "tui-settings",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                ]
            ) == ["opencode", "--session", "SID", "--model", "anthropic/claude-sonnet-4-6"]
        )
        #expect(
            AgentResumeArgv().launcherResolution(
                launcher: "omo",
                sessionId: "SID",
                executablePath: nil,
                arguments: [
                    "cmux",
                    "omo",
                    "tui-settings",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                ]
            ) == .resolved(["cmux", "omo", "--session", "SID", "--model", "anthropic/claude-sonnet-4-6"])
        )
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "opencode",
                sessionId: "SID",
                executablePath: nil,
                arguments: [
                    "opencode",
                    "--agent",
                    "tui-settings",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                ]
            ) == [
                "opencode",
                "--session",
                "SID",
                "--agent",
                "tui-settings",
                "--model",
                "anthropic/claude-sonnet-4-6",
            ]
        )
    }

    @Test("OpenCode direct interactive run resumes in direct interactive mode")
    func opencodeInteractiveRunResumesInInteractiveMode() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "opencode",
                sessionId: "SID",
                executablePath: "/opt/bin/opencode",
                arguments: [
                    "/opt/bin/opencode",
                    "run",
                    "--interactive",
                    "--session", "OLD",
                    "--model", "anthropic/claude-sonnet-4-6",
                    "--auto",
                    "do not replay this prompt",
                ]
            ) == [
                "/opt/bin/opencode",
                "run",
                "--interactive",
                "--session", "SID",
                "--model", "anthropic/claude-sonnet-4-6",
                "--auto",
            ]
        )
    }

    @Test("One-shot provider launches do not manufacture resume commands")
    func oneShotProviderLaunchesDoNotResume() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "rovodev",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["acli", "rovodev", "run", "fix this"]
            ) == nil
        )
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "kimi",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["kimi", "--quiet", "fix this"]
            ) == nil
        )
    }

    @Test("Captured Codex executable is preserved through the wrapper")
    func executablePathOverridesFallback() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "codex",
                sessionId: "SID",
                executablePath: "/opt/bin/codex",
                arguments: ["/opt/bin/codex"]
            ) == ["env", "CMUX_CUSTOM_CODEX_PATH=/opt/bin/codex", "codex", "resume", "SID", "-c", "check_for_update_on_startup=false"]
        )
    }

    @Test("Captured Codex executable routes resume and fork through the wrapper")
    func capturedCodexExecutableRoutesThroughWrapper() throws {
        let executable = "/opt/company/Codex Builds/codex"
        let wrapperPrefix = [
            "env",
            "CMUX_CUSTOM_CODEX_PATH=\(executable)",
            "codex",
        ]

        let resume = try #require(AgentResumeArgv().builtInKind(
            kind: "codex",
            sessionId: "SID",
            executablePath: executable,
            arguments: [executable, "--model", "gpt-5.4"]
        ))
        #expect(
            resume == wrapperPrefix
                + ["resume", "SID", "-c", "check_for_update_on_startup=false", "--model", "gpt-5.4"]
        )

        let fork = try #require(AgentForkArgv().builtInKind(
            kind: "codex",
            sessionId: "SID",
            executablePath: executable,
            arguments: [executable, "--model", "gpt-5.4"]
        ))
        #expect(fork == wrapperPrefix + ["fork", "SID", "--model", "gpt-5.4"])
    }

    @Test("Pi-family replay replaces selectors and preserves provider-specific values")
    func piFamilyReplayUsesCurrentOptionWidths() throws {
        let piArguments = [
            "pi",
            "--session-id", "OLD",
            "--name", "refactor auth",
            "--model", "anthropic/claude-sonnet-4-6",
        ]
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "pi", sessionId: "SID", executablePath: nil, arguments: piArguments
            ) == [
                "pi", "--session", "SID",
                "--name", "refactor auth",
                "--model", "anthropic/claude-sonnet-4-6",
            ]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "pi", sessionId: "SID", executablePath: nil, arguments: piArguments
            ) == [
                "pi", "--fork", "SID",
                "--name", "refactor auth",
                "--model", "anthropic/claude-sonnet-4-6",
            ]
        )

        let ompValues = [
            "--profile", "work",
            "--smol", "haiku",
            "--slow", "opus",
            "--plan", "sonnet",
            "--max-time", "300",
            "--approval-mode", "write",
        ]
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "omp", sessionId: "SID", executablePath: nil, arguments: ["omp"] + ompValues
            ) == ["omp", "--resume", "SID"] + ompValues
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "omp", sessionId: "SID", executablePath: nil, arguments: ["omp"] + ompValues
            ) == nil
        )

        let campfireArguments = [
            "campfire",
            "--session-id", "OLD",
            "--model", "anthropic/claude-sonnet-4-6",
        ]
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "campfire", sessionId: "SID", executablePath: nil, arguments: campfireArguments
            ) == ["campfire", "--session", "SID", "--model", "anthropic/claude-sonnet-4-6"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "campfire", sessionId: "SID", executablePath: nil, arguments: campfireArguments
            ) == ["campfire", "--fork", "SID", "--model", "anthropic/claude-sonnet-4-6"]
        )
    }

    @Test("Pi-family export and list modes are never replayable")
    func piFamilyUtilityModesAreNotReplayable() {
        for kind in ["pi", "omp", "campfire"] {
            #expect(
                AgentResumeArgv().builtInKind(
                    kind: kind,
                    sessionId: "SID",
                    executablePath: nil,
                    arguments: [kind, "--export", "/tmp/session.html"]
                ) == nil,
                "\(kind) export"
            )
            #expect(
                AgentForkArgv().builtInKind(
                    kind: kind,
                    sessionId: "SID",
                    executablePath: nil,
                    arguments: [kind, "list"]
                ) == nil,
                "\(kind) list"
            )
        }
    }

    @Test("Grok replay preserves value widths and drops worktree selectors")
    func grokReplayUsesCurrentOptionWidths() {
        let arguments = [
            "grok",
            "--debug-file", "/tmp/grok debug.log",
            "--json-schema", #"{"type":"object"}"#,
            "--leader-socket", "/tmp/grok leader.sock",
            "--worktree", "feature-old",
            "--worktree-ref", "main",
            "--model", "grok-code-fast-1",
        ]
        let preserved = [
            "--debug-file", "/tmp/grok debug.log",
            "--json-schema", #"{"type":"object"}"#,
            "--leader-socket", "/tmp/grok leader.sock",
            "--model", "grok-code-fast-1",
        ]
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "grok", sessionId: "SID", executablePath: nil, arguments: arguments
            ) == ["grok", "-r", "SID"] + preserved
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "grok", sessionId: "SID", executablePath: nil, arguments: arguments
            ) == ["grok", "--resume", "SID", "--fork-session"] + preserved
        )
    }

    @Test("Codex resume suppresses codex's blocking startup update prompt per-invocation")
    func codexResumeSuppressesStartupUpdatePrompt() {
        // `codex resume <id>` passes no initial prompt, so codex's TUI shows a blocking
        // "Update available!" picker before restoring the session — a cmux relaunch that
        // auto-restores codex panes lands them on that prompt instead of the conversation.
        // The per-invocation `-c` override keeps cmux-driven restores non-interactive
        // without mutating the user's ~/.codex/config.toml, and it precedes the preserved
        // launch arguments so a user-captured explicit override still wins.
        let overrides = ["-c", "check_for_update_on_startup=false"]
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "codex",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["codex", "--model", "gpt-5.4"]
            ) == ["codex", "resume", "SID"] + overrides + ["--model", "gpt-5.4"]
        )
        #expect(
            AgentResumeArgv().launcherResolution(
                launcher: "codexTeams",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["cmux", "codex-teams", "--model", "gpt-5.4"]
            ) == .resolved(["cmux", "codex-teams", "resume", "SID"] + overrides + ["--model", "gpt-5.4"])
        )
    }

    @Test("Codex resume respects an explicit captured check_for_update_on_startup setting")
    func codexResumeRespectsExplicitUpdateCheckSetting() {
        // The codex sanitizer policy preserves `-c key=value` pairs, so a captured
        // explicit setting must stay authoritative (no injected override) and a
        // restore-of-a-restore must not stack duplicate overrides.
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "codex",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["codex", "-c", "check_for_update_on_startup=true"]
            ) == ["codex", "resume", "SID", "-c", "check_for_update_on_startup=true"]
        )
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "codex",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["codex", "-c", "check_for_update_on_startup=false"]
            ) == ["codex", "resume", "SID", "-c", "check_for_update_on_startup=false"]
        )
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "codex",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["codex", "-c=check_for_update_on_startup=true"]
            ) == ["codex", "resume", "SID", "-c=check_for_update_on_startup=true"]
        )
        #expect(
            AgentResumeArgv().launcherResolution(
                launcher: "codexTeams",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["cmux", "codex-teams", "-c", "check_for_update_on_startup=true"]
            ) == .resolved(["cmux", "codex-teams", "resume", "SID", "-c", "check_for_update_on_startup=true"])
        )
    }

    @Test("cmux wrapper launchers resolve before per-kind verbs")
    func launcherWrappers() {
        #expect(
            AgentResumeArgv().launcherResolution(
                launcher: "claudeTeams", sessionId: "SID", executablePath: nil, arguments: ["cmux", "claude-teams"]
            ) == .resolved(["cmux", "claude-teams", "--resume", "SID"])
        )
        #expect(
            AgentResumeArgv().launcherResolution(
                launcher: "claudeTeams",
                sessionId: "SID",
                executablePath: nil,
                arguments: [
                    "cmux",
                    "claude-teams",
                    "--worktree",
                    "/tmp/team repo",
                    "--tmux",
                    "please",
                    "--permission-mode",
                    "bypassPermissions",
                ]
            ) == .resolved([
                "cmux",
                "claude-teams",
                "--resume",
                "SID",
                "--worktree",
                "/tmp/team repo",
            ])
        )
        #expect(
            AgentResumeArgv().launcherResolution(
                launcher: "codexTeams", sessionId: "SID", executablePath: nil, arguments: ["cmux", "codex-teams"]
            ) == .resolved(["cmux", "codex-teams", "resume", "SID", "-c", "check_for_update_on_startup=false"])
        )
        #expect(
            AgentResumeArgv().launcherResolution(
                launcher: "omo", sessionId: "SID", executablePath: nil, arguments: ["cmux", "omo"]
            ) == .resolved(["cmux", "omo", "--session", "SID"])
        )
        // One-shot wrappers have no resumable form (omx and omc share an arm; exercise each).
        #expect(
            AgentResumeArgv().launcherResolution(
                launcher: "omx", sessionId: "SID", executablePath: nil, arguments: ["cmux", "omx"]
            ) == .resolved(nil)
        )
        #expect(
            AgentResumeArgv().launcherResolution(
                launcher: "omc", sessionId: "SID", executablePath: nil, arguments: ["cmux", "omc"]
            ) == .resolved(nil)
        )
        // A plain agent launcher falls through to the per-kind builder.
        #expect(
            AgentResumeArgv().launcherResolution(
                launcher: "claude", sessionId: "SID", executablePath: nil, arguments: ["claude"]
            ) == .passthrough
        )
        #expect(
            AgentResumeArgv().launcherResolution(
                launcher: nil, sessionId: "SID", executablePath: nil, arguments: []
            ) == .passthrough
        )
    }

    @Test("Portable claude resume command wraps the POSIX rendering for any login shell")
    func portableClaudeResumeShellCommand() {
        #expect(
            AgentResumeArgv.portableClaudeResumeShellCommand(posixCommand: "claude --resume SID")
                == "/bin/sh -c 'claude --resume SID'"
        )
        // Embedded single quotes survive via the POSIX '\'' escape, so quoted env
        // prefixes and argv words round-trip through the nested sh layer.
        #expect(
            AgentResumeArgv.portableClaudeResumeShellCommand(
                posixCommand: "'env' 'A=b c' claude '--resume' 'SID'"
            ) == "/bin/sh -c ''\\''env'\\'' '\\''A=b c'\\'' claude '\\''--resume'\\'' '\\''SID'\\'''"
        )
    }

    @Test("Rendered portable command wraps only when the wrapper token was substituted")
    func renderedPortableClaudeResumeShellCommand() {
        let quote: (String) -> String = { "'" + $0 + "'" }
        // Bare `claude` executable: token substituted, command wrapped for non-POSIX shells.
        let substituted = "'env' 'A=b' \(AgentResumeArgv.claudeWrapperShellExecutableToken) '--resume' 'SID'"
        #expect(
            AgentResumeArgv.renderedPortableClaudeResumeShellCommand(
                parts: ["env", "A=b", "claude", "--resume", "SID"],
                quote: quote
            ) == "/bin/sh -c '" + substituted.replacingOccurrences(of: "'", with: "'\\''") + "'"
        )
        // Launcher resumes that resolve to cmux's own CLI emit no bare `claude`:
        // already-portable quoted words stay unwrapped.
        #expect(
            AgentResumeArgv.renderedPortableClaudeResumeShellCommand(
                parts: ["/Applications/cmux.app/Contents/Resources/bin/cmux", "claude-teams", "--resume", "SID"],
                quote: quote
            ) == "'/Applications/cmux.app/Contents/Resources/bin/cmux' 'claude-teams' '--resume' 'SID'"
        )
    }

    @Test("Codex wrapper token resolves CMUX_CODEX_WRAPPER_SHIM, degrading to bare codex")
    func codexWrapperShellExecutableToken() {
        #expect(
            AgentResumeArgv.codexWrapperShellExecutableToken
                == "\"$([ -x \"${CMUX_CODEX_WRAPPER_SHIM:-}\" ] && printf '%s' \"$CMUX_CODEX_WRAPPER_SHIM\" || printf codex)\""
        )
    }

    @Test("Portable codex resume command wraps the POSIX rendering for any login shell")
    func portableCodexResumeShellCommand() {
        #expect(
            AgentResumeArgv.portableCodexResumeShellCommand(posixCommand: "codex resume SID")
                == "/bin/sh -c 'codex resume SID'"
        )
    }

    @Test("Rendered codex resume substitutes the wrapper token and wraps in /bin/sh -c")
    func renderedPortableCodexResumeShellCommand() {
        let quote: (String) -> String = { "'" + $0 + "'" }
        // Bare `codex` executable: token substituted, command wrapped for non-POSIX shells.
        let substituted = "\(AgentResumeArgv.codexWrapperShellExecutableToken) 'resume' 'SID'"
        let rendered = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
            parts: ["codex", "resume", "SID"],
            quote: quote
        )
        #expect(rendered == "/bin/sh -c '" + substituted.replacingOccurrences(of: "'", with: "'\\''") + "'")
        #expect(rendered.hasPrefix("/bin/sh -c "))
        // No bare `codex` executable: already-portable words stay unwrapped.
        #expect(
            AgentResumeArgv.renderedPortableCodexResumeShellCommand(
                parts: ["/Applications/cmux.app/Contents/Resources/bin/cmux", "codex-teams", "resume", "SID"],
                quote: quote
            ) == "'/Applications/cmux.app/Contents/Resources/bin/cmux' 'codex-teams' 'resume' 'SID'"
        )
    }
}
