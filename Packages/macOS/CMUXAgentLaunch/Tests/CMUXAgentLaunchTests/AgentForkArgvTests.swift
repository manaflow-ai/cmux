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
