import CMUXAgentLaunch
import Testing

@Suite("Codex resume trust policy")
struct CodexResumeTrustPolicyTests {
    private let policy = CodexResumeTrustPolicy()

    @Test("Undecided resume defaults to untrusted for this invocation")
    func undecidedResumeDefaultsToUntrusted() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: ["/Users/me/.bun/bin/codex", "resume", "SID", "--yolo"],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                userConfigContents: """
                [projects."/Users/me"]
                trust_level = "trusted"
                """
            ) == [
                "-c",
                "projects.\"/Users/me/worktree\".trust_level=\"untrusted\"",
            ]
        )
    }

    @Test("Explicit cwd and repository decisions remain authoritative")
    func explicitConfigDecisionsRemainAuthoritative() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: ["codex", "resume", "SID"],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                userConfigContents: """
                [projects."/Users/me/worktree"]
                trust_level = "untrusted"
                """
            ).isEmpty
        )
        #expect(
            policy.undecidedProjectOverride(
                arguments: ["codex", "resume", "SID"],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                userConfigContents: """
                [projects."/Users/me/repo"]
                trust_level = "trusted"
                """
            ).isEmpty
        )
    }

    @Test("Explicit launch override remains authoritative")
    func explicitLaunchOverrideRemainsAuthoritative() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: [
                    "codex",
                    "-c",
                    "projects.\"/Users/me/repo\".trust_level=\"trusted\"",
                    "resume",
                    "SID",
                ],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                userConfigContents: nil
            ).isEmpty
        )
    }

    @Test("Fresh sessions never receive an automatic trust decision")
    func freshSessionsRemainInteractive() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: ["codex", "--model", "gpt-5.6"],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                userConfigContents: nil
            ).isEmpty
        )
    }

    @Test("Inline project decisions are recognized")
    func inlineProjectDecisionsAreRecognized() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: ["codex", "resume", "SID"],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                userConfigContents:
                    #"projects = { "/Users/me/repo" = { trust_level = "trusted" } }"#
            ).isEmpty
        )
    }
}
