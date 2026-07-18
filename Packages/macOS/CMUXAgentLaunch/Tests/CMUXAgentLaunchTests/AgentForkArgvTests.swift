import CMUXAgentLaunch
import Testing

@Suite("AgentForkArgv")
struct AgentForkArgvTests {
    @Test("Built-in forkable kinds")
    func builtInForkableKinds() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: "/opt/bin/claude",
                arguments: ["/opt/bin/claude", "--model", "sonnet"]
            ) == ["claude", "--resume", "SID", "--fork-session", "--model", "sonnet"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "SID",
                executablePath: "/opt/bin/codex",
                arguments: ["/opt/bin/codex", "--model", "gpt-5"]
            ) == ["env", "CMUX_CUSTOM_CODEX_PATH=/opt/bin/codex", "codex", "fork", "SID", "--model", "gpt-5"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "opencode",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["opencode", "--model", "anthropic/claude-sonnet-4-6"]
            ) == ["opencode", "--session", "SID", "--fork", "--model", "anthropic/claude-sonnet-4-6"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "pi",
                sessionId: "SID",
                executablePath: "/opt/bin/pi",
                arguments: ["/opt/bin/pi", "--model", "anthropic/claude-sonnet-4-6"]
            ) == ["/opt/bin/pi", "--fork", "SID", "--model", "anthropic/claude-sonnet-4-6"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "omp",
                sessionId: "SID",
                executablePath: "/opt/bin/omp",
                arguments: ["/opt/bin/omp", "--model", "anthropic/claude-sonnet-4-6"]
            ) == ["/opt/bin/omp", "--fork", "SID", "--model", "anthropic/claude-sonnet-4-6"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "campfire",
                sessionId: "SID",
                executablePath: "/opt/bin/campfire",
                arguments: ["/opt/bin/campfire", "--model", "anthropic/claude-sonnet-4-6"]
            ) == ["/opt/bin/campfire", "--fork", "SID", "--model", "anthropic/claude-sonnet-4-6"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "grok",
                sessionId: "SID",
                executablePath: "/opt/bin/grok",
                arguments: ["/opt/bin/grok", "--resume", "OLD", "--fork-session", "--model", "grok-4"]
            ) == ["/opt/bin/grok", "--resume", "SID", "--fork-session", "--model", "grok-4"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "amp",
                sessionId: "SID",
                executablePath: "/opt/bin/amp",
                arguments: ["/opt/bin/amp", "threads", "continue", "OLD", "--mode", "smart"]
            ) == ["/opt/bin/amp", "threads", "fork", "SID", "--mode", "smart"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "amp",
                sessionId: "CHILD",
                executablePath: "/opt/bin/amp",
                arguments: ["/opt/bin/amp", "threads", "fork", "PARENT", "--mode", "smart"]
            ) == ["/opt/bin/amp", "threads", "fork", "CHILD", "--mode", "smart"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "factory",
                sessionId: "SID",
                executablePath: "/opt/bin/droid",
                arguments: ["/opt/bin/droid", "--resume", "OLD", "--settings", "/tmp/settings.json"]
            ) == ["/opt/bin/droid", "--fork", "SID", "--settings", "/tmp/settings.json"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codebuddy",
                sessionId: "SID",
                executablePath: "/opt/bin/codebuddy",
                arguments: ["/opt/bin/codebuddy", "--resume", "OLD", "--fork-session", "--model", "glm-5"]
            ) == ["/opt/bin/codebuddy", "--resume", "SID", "--fork-session", "--model", "glm-5"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "qoder",
                sessionId: "SID",
                executablePath: "/opt/bin/qodercli",
                arguments: ["/opt/bin/qodercli", "--resume", "OLD", "--fork-session", "--model", "qoder"]
            ) == ["/opt/bin/qodercli", "--resume", "SID", "--fork-session", "--model", "qoder"]
        )
    }

    @Test("Codex one-shot commands are not forkable")
    func codexOneShotCommandsAreNotForkable() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "SID",
                executablePath: "/opt/bin/codex",
                arguments: ["/opt/bin/codex", "exec", "make", "test"]
            ) == nil
        )
    }

    @Test("Codex fork captures preserve prompt tags")
    func codexForkCapturesPreservePromptTags() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "CHILD",
                executablePath: "/opt/bin/codex",
                arguments: [
                    "/opt/bin/codex",
                    "fork",
                    "019ef275-74e3-7777-9773-9dcb118ed5ad",
                    "tag-one",
                    "tag two",
                    "--model",
                    "gpt-5"
                ]
            ) == ["env", "CMUX_CUSTOM_CODEX_PATH=/opt/bin/codex", "codex", "fork", "CHILD", "tag-one", "tag two", "--model", "gpt-5"]
        )
    }

    @Test("Codex fork captures preserve command-shaped prompt tags")
    func codexForkCapturesPreserveCommandShapedPromptTags() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "CHILD",
                executablePath: "/opt/bin/codex",
                arguments: [
                    "/opt/bin/codex",
                    "fork",
                    "019ef275-74e3-7777-9773-9dcb118ed5ad",
                    "exec",
                    "review",
                    "help",
                    "fork",
                    "resume",
                    "--model",
                    "gpt-5"
                ]
            ) == ["env", "CMUX_CUSTOM_CODEX_PATH=/opt/bin/codex", "codex", "fork", "CHILD", "exec", "review", "help", "fork", "resume", "--model", "gpt-5"]
        )
    }

    @Test("Codex normal prompt captures do not replay prompts when forked")
    func codexNormalPromptCapturesDoNotReplayPrompts() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "CHILD",
                executablePath: "/opt/bin/codex",
                arguments: [
                    "/opt/bin/codex",
                    "--model",
                    "gpt-5",
                    "initial prompt should not replay",
                ]
            ) == ["env", "CMUX_CUSTOM_CODEX_PATH=/opt/bin/codex", "codex", "fork", "CHILD", "--model", "gpt-5"]
        )
    }

    @Test("Codex fork captures preserve options after prompt tags")
    func codexForkCapturesPreserveOptionsAfterPromptTags() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "CHILD",
                executablePath: "/opt/bin/codex",
                arguments: [
                    "/opt/bin/codex",
                    "fork",
                    "019ef275-74e3-7777-9773-9dcb118ed5ad",
                    "tag-one",
                    "--sandbox",
                    "danger-full-access",
                ]
            ) == ["env", "CMUX_CUSTOM_CODEX_PATH=/opt/bin/codex", "codex", "fork", "CHILD", "tag-one", "--sandbox", "danger-full-access"]
        )
    }

    @Test("cmux wrapper launchers use fork verbs")
    func launcherWrappersUseForkVerbs() {
        #expect(
            AgentForkArgv().launcherResolution(
                launcher: "claudeTeams",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["cmux", "claude-teams", "--worktree", "/tmp/team repo"]
            ) == .resolved(["cmux", "claude-teams", "--resume", "SID", "--fork-session", "--worktree", "/tmp/team repo"])
        )
        #expect(
            AgentForkArgv().launcherResolution(
                launcher: "codexTeams",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["cmux", "codex-teams", "--model", "gpt-5"]
            ) == .resolved(["cmux", "codex-teams", "fork", "SID", "--model", "gpt-5"])
        )
        #expect(
            AgentForkArgv().launcherResolution(
                launcher: "omo",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["cmux", "omo", "--model", "anthropic/claude-sonnet-4-6"]
            ) == .resolved(["cmux", "omo", "--session", "SID", "--fork", "--model", "anthropic/claude-sonnet-4-6"])
        )
        #expect(
            AgentForkArgv().launcherResolution(
                launcher: "omx",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["cmux", "omx"]
            ) == .resolved(nil)
        )
    }

    @Test("Agents without a documented fork entrypoint stay unsupported")
    func unsupportedAgentsStayUnsupported() {
        #expect(
            AgentForkArgv().builtInKind(kind: "gemini", sessionId: "SID", executablePath: nil, arguments: ["gemini"]) == nil
        )
        #expect(
            AgentForkArgv().builtInKind(kind: "cursor", sessionId: "SID", executablePath: nil, arguments: ["cursor-agent"]) == nil
        )
    }

    @Test("OpenCode direct interactive run forks in direct interactive mode")
    func opencodeInteractiveRunForksInInteractiveMode() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "opencode",
                sessionId: "PARENT",
                executablePath: "/opt/bin/opencode",
                arguments: [
                    "/opt/bin/opencode",
                    "run",
                    "-i",
                    "--session", "OLD",
                    "--model", "anthropic/claude-sonnet-4-6",
                    "--auto",
                    "do not replay this prompt",
                ]
            ) == [
                "/opt/bin/opencode",
                "run",
                "--interactive",
                "--session", "PARENT",
                "--fork",
                "--model", "anthropic/claude-sonnet-4-6",
                "--auto",
            ]
        )
    }

    @Test("One-shot provider launches are not forkable")
    func oneShotProviderLaunchesAreNotForkable() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "rovodev",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["acli", "rovodev", "run", "fix this"]
            ) == nil
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "kimi",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["kimi", "--quiet", "fix this"]
            ) == nil
        )
    }
}
