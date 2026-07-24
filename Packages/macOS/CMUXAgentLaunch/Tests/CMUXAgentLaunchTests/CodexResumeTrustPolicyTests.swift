import CMUXAgentLaunch
import Darwin
import Foundation
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
                #"projects={"/Users/me/worktree"={trust_level="untrusted"}}"#,
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

    @Test("Project trust before resume is ignored by the resume parser")
    func globalScopedLaunchOverrideIsNotAuthoritative() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: [
                    "codex",
                    "-c",
                    #"projects={"/Users/me/repo"={trust_level="trusted"}}"#,
                    "resume",
                    "SID",
                ],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                userConfigContents: nil
            ) == [
                "-c",
                #"projects={"/Users/me/worktree"={trust_level="untrusted"}}"#,
            ]
        )
    }

    @Test("Project trust after resume remains authoritative")
    func resumeScopedLaunchOverrideRemainsAuthoritative() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: [
                    "codex",
                    "resume",
                    "SID",
                    "-c",
                    #"projects={"/Users/me/repo"={trust_level="trusted"}}"#,
                ],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                userConfigContents: nil
            ).isEmpty
        )
    }

    @Test("Unquoted resume trust values follow Codex's raw string fallback")
    func unquotedResumeTrustValueRemainsAuthoritative() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: [
                    "codex",
                    "resume",
                    "SID",
                    "-c",
                    "projects./Users/me/repo.trust_level=trusted",
                ],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                userConfigContents: nil
            ).isEmpty
        )
    }

    @Test("Ineffective quoted dotted launch override is replaced")
    func ineffectiveQuotedDottedOverrideIsReplaced() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: [
                    "codex",
                    "-c",
                    #"projects."/Users/me/work.tree".trust_level="trusted""#,
                    "resume",
                    "SID",
                ],
                currentDirectory: "/Users/me/work.tree",
                repositoryRoot: nil,
                userConfigContents: nil
            ) == [
                "-c",
                #"projects={"/Users/me/work.tree"={trust_level="untrusted"}}"#,
            ]
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

    @Test("A value named resume does not turn a fresh launch into a resume")
    func optionValueNamedResumeRemainsFresh() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: ["codex", "--add-dir", "resume"],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                userConfigContents: nil
            ).isEmpty
        )
    }

    @Test("Codex -C selects the trust lookup directory")
    func workingDirectoryOptionSelectsTrustDirectory() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: [
                    "codex",
                    "-C",
                    "/Users/me/other-worktree",
                    "resume",
                    "SID",
                ],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: nil,
                userConfigContents: nil
            ) == [
                "-c",
                #"projects={"/Users/me/other-worktree"={trust_level="untrusted"}}"#,
            ]
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

    @Test("Undecided override targets Codex's canonical working directory")
    func undecidedOverrideTargetsCanonicalWorkingDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-trust-\(UUID().uuidString)", isDirectory: true)
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fileManager.createDirectory(at: actual, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: actual)
        defer { try? fileManager.removeItem(at: root) }

        let canonical = actual.path.withCString { pointer -> String in
            guard let resolved = Darwin.realpath(pointer, nil) else { return actual.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        #expect(
            policy.undecidedProjectOverride(
                arguments: ["codex", "resume", "SID"],
                currentDirectory: alias.path,
                repositoryRoot: nil,
                userConfigContents: nil
            ) == [
                "-c",
                #"projects={"\#(canonical)"={trust_level="untrusted"}}"#,
            ]
        )
    }

    @Test("A logical symlink decision does not satisfy Codex's canonical lookup")
    func logicalSymlinkDecisionDoesNotSuppressCanonicalOverride() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-trust-\(UUID().uuidString)", isDirectory: true)
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fileManager.createDirectory(at: actual, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: actual)
        defer { try? fileManager.removeItem(at: root) }

        let canonical = actual.path.withCString { pointer -> String in
            guard let resolved = Darwin.realpath(pointer, nil) else { return actual.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        #expect(
            policy.undecidedProjectOverride(
                arguments: ["codex", "resume", "SID"],
                currentDirectory: alias.path,
                repositoryRoot: nil,
                userConfigContents: """
                [projects."\(alias.path)"]
                trust_level = "trusted"
                """
            ) == [
                "-c",
                #"projects={"\#(canonical)"={trust_level="untrusted"}}"#,
            ]
        )
    }

    @Test("macOS tmp alias resolves to the filesystem path Codex evaluates")
    func macOSTemporaryDirectoryAliasUsesPrivatePath() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: ["codex", "resume", "SID"],
                currentDirectory: "/tmp",
                repositoryRoot: nil,
                userConfigContents: nil
            ) == [
                "-c",
                #"projects={"/private/tmp"={trust_level="untrusted"}}"#,
            ]
        )
    }
}
