import CMUXAgentLaunch
import Testing

@Suite("AgentResumeArgv")
struct AgentResumeArgvTests {
    @Test("Built-in --option style kinds", arguments: [
        ("claude", "claude", ["claude", "--resume", "SID"]),
        ("grok", "grok", ["grok", "-r", "SID"]),
        ("pi", "pi", ["pi", "--session", "SID"]),
        ("omp", "omp", ["omp", "--session", "SID"]),
        ("cursor", "cursor-agent", ["cursor-agent", "--resume", "SID"]),
        ("gemini", "gemini", ["gemini", "--resume", "SID"]),
        ("antigravity", "agy", ["agy", "--conversation", "SID"]),
        ("copilot", "copilot", ["copilot", "--resume", "SID"]),
        ("codebuddy", "codebuddy", ["codebuddy", "--resume", "SID"]),
        ("factory", "droid", ["droid", "--resume", "SID"]),
        ("qoder", "qodercli", ["qodercli", "--resume", "SID"]),
    ])
    func builtInWithOptionKinds(kind: String, executable: String, expected: [String]) {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: kind, sessionId: "SID", executablePath: nil, arguments: [executable]
            ) == expected
        )
    }

    @Test("Built-in special-shaped kinds")
    func builtInSpecialShapes() {
        #expect(
            AgentResumeArgv().builtInKind(kind: "codex", sessionId: "SID", executablePath: nil, arguments: ["codex"])
                == ["codex", "resume", "SID"]
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

    @Test("Captured executable path overrides the fallback executable")
    func executablePathOverridesFallback() {
        // Non-claude kinds replay the captured executable path verbatim.
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "codex",
                sessionId: "SID",
                executablePath: "/opt/bin/codex",
                arguments: ["/opt/bin/codex"]
            ) == ["/opt/bin/codex", "resume", "SID"]
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
            ) == .resolved(["cmux", "codex-teams", "resume", "SID"])
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
}
