import CMUXAgentLaunch
import Testing

@Suite("AgentResumeWorkingDirectory")
struct AgentResumeWorkingDirectoryTests {
    @Test("Claude resumes from the worktree that owns its transcript", arguments: [false, true])
    func claudeTranscriptOverridesStaleLaunchDirectory(nested: Bool) {
        let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let transcript = "/custom/claude/projects/-Users-x-repo--claude-worktrees-feature/"
            + (nested ? "\(sessionID)/messages/" : "") + "\(sessionID).jsonl"
        #expect(AgentResumeWorkingDirectory().resolve(
            kind: "claude",
            runtimeCwd: "/Users/x/repo/.claude/worktrees/feature",
            launchWorkingDirectory: "/Users/x/repo",
            transcriptPath: transcript
        ) == "/Users/x/repo/.claude/worktrees/feature")
    }

    @Test("Claude uses the final projects directory in a nested transcript path")
    func claudeTranscriptUsesFinalProjectsDirectory() {
        let transcript = "/Users/x/projects/.claude/projects/-Users-x-repo--claude-worktrees-feature/session.jsonl"
        #expect(AgentResumeWorkingDirectory().resolve(
            kind: "claude",
            runtimeCwd: "/Users/x/repo/.claude/worktrees/feature",
            launchWorkingDirectory: "/Users/x/repo",
            transcriptPath: transcript
        ) == "/Users/x/repo/.claude/worktrees/feature")
    }

    @Test("Claude project slugs preserve non-ASCII and punctuation normalization")
    func claudeTranscriptMatchesGeneralProjectSlug() {
        let transcript = "/custom/claude/projects/-Users-a-my-proj-v2-home--/session.jsonl"
        #expect(AgentResumeWorkingDirectory().resolve(
            kind: "claude",
            runtimeCwd: "/Users/a/my_proj.v2/home/é",
            launchWorkingDirectory: "/Users/a",
            transcriptPath: transcript
        ) == "/Users/a/my_proj.v2/home/é")
    }

    @Test("Directory-namespaced agents pin the launch cwd over a drifted runtime cwd")
    func directoryNamespacedPrefersLaunch() {
        #expect(
            AgentResumeWorkingDirectory().resolve(
                kind: "claude",
                runtimeCwd: "/Users/x/repo/worktrees/feature",
                launchWorkingDirectory: "/Users/x/repo"
            ) == "/Users/x/repo"
        )
        for kind in ["gemini", "cursor", "grok", "pi", "omp", "qoder"] {
            #expect(AgentResumeWorkingDirectory().cwdNamespacing(forKind: kind) == .byDirectory)
            #expect(
                AgentResumeWorkingDirectory().resolve(
                    kind: kind,
                    runtimeCwd: "/Users/x/repo/sub",
                    launchWorkingDirectory: "/Users/x/repo"
                ) == "/Users/x/repo"
            )
        }
    }

    @Test("Id-keyed cwd-in-file agents keep the runtime cwd")
    func cwdInFileKeepsRuntime() {
        for kind in ["codex", "opencode", "amp", "antigravity", "rovodev", "hermes-agent"] {
            #expect(AgentResumeWorkingDirectory().cwdNamespacing(forKind: kind) == .cwdInFile)
            #expect(
                AgentResumeWorkingDirectory().resolve(
                    kind: kind,
                    runtimeCwd: "/Users/x/repo/worktrees/feature",
                    launchWorkingDirectory: "/Users/x/repo"
                ) == "/Users/x/repo/worktrees/feature"
            )
        }
    }

    @Test("Falls back across inputs and treats empty as absent")
    func fallbacksAndEmpty() {
        #expect(
            AgentResumeWorkingDirectory().resolve(
                kind: "claude", runtimeCwd: "/Users/x/repo", launchWorkingDirectory: nil
            ) == "/Users/x/repo"
        )
        #expect(
            AgentResumeWorkingDirectory().resolve(
                kind: "claude", runtimeCwd: "/Users/x/repo", launchWorkingDirectory: "   "
            ) == "/Users/x/repo"
        )
        #expect(
            AgentResumeWorkingDirectory().resolve(
                kind: "claude", runtimeCwd: nil, launchWorkingDirectory: ""
            ) == nil
        )
        // Unknown kinds prefer the launch cwd (never worse for resume lookup).
        #expect(AgentResumeWorkingDirectory().cwdNamespacing(forKind: "some-future-agent") == .byDirectory)
    }
}
