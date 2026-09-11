import CMUXAgentLaunch
import Testing

@Suite("Agent launch sanitizer additional coverage")
struct AgentLaunchSanitizerAdditionalTests {
    @Test("Preserves ambiguous short options without agent semantics")
    func preservesAmbiguousShortWorkingDirectoryOptions() {
        let splitWorktree = ["cmux", "claude-teams", "-w", "/tmp/team-worktree", "--model", "sonnet"]
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: splitWorktree,
                workingDirectory: "/tmp/team-worktree"
            ) == splitWorktree
        )

        let attachedWorktree = ["cmux", "claude-teams", "-w/tmp/team-worktree", "--model", "sonnet"]
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: attachedWorktree,
                workingDirectory: nil,
                removeAllWorkingDirectoryOptions: true
            ) == attachedWorktree
        )

        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["qoder", "-w", "/tmp/project", "--model", "best"],
                workingDirectory: "/tmp/project",
                agentKind: "qoder"
            ) == ["qoder", "--model", "best"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["kimi", "--resume", "session", "-w/local/repo", "--model", "kimi-k2"],
                workingDirectory: nil,
                agentKind: "kimi",
                removeAllWorkingDirectoryOptions: true
            ) == ["kimi", "--resume", "session", "--model", "kimi-k2"]
        )
    }

    @Test("Removes every cwd option while preserving arguments after the boundary")
    func removesWorkingDirectoryOptions() {
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["kimi", "--resume", "session", "--work-dir", "/local/repo", "--model", "kimi-k2"],
                workingDirectory: nil,
                removeAllWorkingDirectoryOptions: true
            ) == ["kimi", "--resume", "session", "--model", "kimi-k2"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["grok", "-r", "session", "--cwd=/local/repo", "--", "--cwd", "prompt text"],
                workingDirectory: nil,
                removeAllWorkingDirectoryOptions: true
            ) == ["grok", "-r", "session", "--", "--cwd", "prompt text"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["grok", "-r", "session", "--cwd", "--", "--cwd", "prompt text"],
                workingDirectory: nil,
                removeAllWorkingDirectoryOptions: true
            ) == ["grok", "-r", "session", "--", "--cwd", "prompt text"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["grok", "-r", "session", "--cwd"],
                workingDirectory: nil,
                removeAllWorkingDirectoryOptions: true
            ) == ["grok", "-r", "session"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["qoder", "--workspace", "/tmp/other", "--cwd", "/tmp/project"],
                workingDirectory: nil,
                agentKind: "qoder",
                removeAllWorkingDirectoryOptions: true
            ) == ["qoder", "--workspace", "/tmp/other"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["cursor-agent", "resume", "session", "--workspace", "/local/repo", "--model", "fast"],
                workingDirectory: nil,
                agentKind: "cursor",
                removeAllWorkingDirectoryOptions: true
            ) == ["cursor-agent", "resume", "session", "--model", "fast"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["grok", "-r", "session", "--cwd", "--model", "grok-4"],
                workingDirectory: nil,
                removeAllWorkingDirectoryOptions: true
            ) == ["grok", "-r", "session", "--model", "grok-4"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["codex", "resume", "session", "-C/local/repo", "--model", "gpt-5.4"],
                workingDirectory: nil,
                agentKind: "codex",
                removeAllWorkingDirectoryOptions: true
            ) == ["codex", "resume", "session", "--model", "gpt-5.4"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["kimi", "--resume", "session", "-Continue", "--model", "kimi-k2"],
                workingDirectory: nil,
                agentKind: "kimi",
                removeAllWorkingDirectoryOptions: true
            ) == ["kimi", "--resume", "session", "-Continue", "--model", "kimi-k2"]
        )
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: ["custom-agent", "-Color", "always"],
                workingDirectory: nil,
                agentKind: "custom-agent",
                removeAllWorkingDirectoryOptions: true
            ) == ["custom-agent", "-Color", "always"]
        )
        let unknownAgentConfig = ["custom-agent", "-C", "/etc/custom-agent.conf", "--session", "session-id"]
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: unknownAgentConfig,
                workingDirectory: nil,
                agentKind: "custom-agent",
                removeAllWorkingDirectoryOptions: true
            ) == unknownAgentConfig
        )
        let customWorkspaceConfig = ["custom-agent", "--workspace", "profile-a", "--cwd", "/tmp/local"]
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: customWorkspaceConfig,
                workingDirectory: nil,
                agentKind: "custom-agent",
                removeAllWorkingDirectoryOptions: true
            ) == ["custom-agent", "--workspace", "profile-a"]
        )
        let customKimiProfile = ["custom-kimi", "-w", "profile-a", "--model", "custom"]
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: customKimiProfile,
                workingDirectory: nil,
                agentKind: nil,
                removeAllWorkingDirectoryOptions: true
            ) == customKimiProfile
        )
    }

    @Test(
        "Matches cwd option semantics without agent-kind case sensitivity",
        arguments: ["Codex", "KIMI", "QoDeR"]
    )
    func matchesCaseInsensitiveAgentKinds(agentKind: String) {
        let option = agentKind.lowercased() == "codex" ? "-C/local/repo" : "-w/local/repo"
        #expect(
            AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: [agentKind, option, "--model", "test"],
                workingDirectory: nil,
                agentKind: agentKind,
                removeAllWorkingDirectoryOptions: true
            ) == [agentKind, "--model", "test"]
        )
    }
}
