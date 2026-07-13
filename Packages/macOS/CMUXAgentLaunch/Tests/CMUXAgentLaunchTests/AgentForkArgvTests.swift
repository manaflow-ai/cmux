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
            ) == ["/opt/bin/codex", "fork", "SID", "--model", "gpt-5"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "opencode",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["opencode", "--model", "anthropic/claude-sonnet-4-6"]
            ) == ["opencode", "--session", "SID", "--fork", "--model", "anthropic/claude-sonnet-4-6"]
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
            ) == ["/opt/bin/codex", "fork", "CHILD", "tag-one", "tag two", "--model", "gpt-5"]
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
            ) == ["/opt/bin/codex", "fork", "CHILD", "exec", "review", "help", "fork", "resume", "--model", "gpt-5"]
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
            ) == ["/opt/bin/codex", "fork", "CHILD", "--model", "gpt-5"]
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
            ) == ["/opt/bin/codex", "fork", "CHILD", "tag-one", "--sandbox", "danger-full-access"]
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

    @Test("Unsupported agents stay unsupported")
    func unsupportedAgentsStayUnsupported() {
        #expect(
            AgentForkArgv().builtInKind(kind: "grok", sessionId: "SID", executablePath: nil, arguments: ["grok"]) == nil
        )
        #expect(
            AgentForkArgv().builtInKind(kind: "amp", sessionId: "SID", executablePath: nil, arguments: ["amp"]) == nil
        )
    }
}
