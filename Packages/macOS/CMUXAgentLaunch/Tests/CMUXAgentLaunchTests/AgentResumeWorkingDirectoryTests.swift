import CMUXAgentLaunch
import Testing

@Suite("AgentResumeWorkingDirectory")
struct AgentResumeWorkingDirectoryTests {
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
