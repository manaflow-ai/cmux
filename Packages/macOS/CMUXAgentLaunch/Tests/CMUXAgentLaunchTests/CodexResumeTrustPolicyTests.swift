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
                effectiveProjectDecisionPaths: ["/Users/me"]
            ) == [
                "-c",
                #"projects={"/Users/me/worktree"={trust_level="untrusted"}}"#,
            ]
        )
    }

    @Test("Effective cwd and repository decisions remain authoritative")
    func effectiveDecisionsRemainAuthoritative() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: ["codex", "resume", "SID"],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                effectiveProjectDecisionPaths: ["/Users/me/worktree"]
            ).isEmpty
        )
        #expect(
            policy.undecidedProjectOverride(
                arguments: ["codex", "resume", "SID"],
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                effectiveProjectDecisionPaths: ["/Users/me/repo"]
            ).isEmpty
        )
    }

    @Test("Fresh sessions never receive or query an automatic trust decision")
    func freshSessionsRemainInteractive() {
        let arguments = ["codex", "--model", "gpt-5.6"]
        #expect(policy.appServerConfigurationArguments(arguments: arguments) == nil)
        #expect(
            policy.undecidedProjectOverride(
                arguments: arguments,
                currentDirectory: "/Users/me/worktree",
                repositoryRoot: "/Users/me/repo",
                effectiveProjectDecisionPaths: []
            ).isEmpty
        )
    }

    @Test("An option value named resume remains a fresh launch")
    func optionValueNamedResumeRemainsFresh() {
        let arguments = ["codex", "--add-dir", "resume"]
        #expect(policy.appServerConfigurationArguments(arguments: arguments) == nil)
        #expect(policy.isResumeInvocation(arguments: arguments) == false)
    }

    @Test("Effective config query replays profile, config, and strict mode")
    func appServerArgumentsReplayConfiguration() {
        #expect(
            policy.appServerConfigurationArguments(
                arguments: [
                    "codex",
                    "-c",
                    #"projects={"/Users/me/root"={trust_level="trusted"}}"#,
                    "--profile",
                    "global",
                    "resume",
                    "SID",
                    "--profile=restored",
                    "--config=projects./Users/me/resume.trust_level=untrusted",
                    "--strict-config",
                    "--",
                    "-c",
                    "projects.ignored.trust_level=trusted",
                ]
            ) == [
                "--profile",
                "restored",
                "-c",
                #"projects={"/Users/me/root"={trust_level="trusted"}}"#,
                "-c",
                "projects./Users/me/resume.trust_level=untrusted",
                "--strict-config",
            ]
        )
    }

    @Test("Remote app-server resumes fail closed")
    func remoteResumeDoesNotQueryLocalConfig() {
        #expect(
            policy.appServerConfigurationArguments(
                arguments: ["codex", "--remote", "unix:///tmp/codex.sock", "resume", "SID"]
            ) == nil
        )
    }

    @Test("The last selected Codex profile applies")
    func selectedResumeProfileUsesLastOccurrence() {
        #expect(
            policy.selectedProfile(
                arguments: [
                    "codex",
                    "--profile",
                    "global",
                    "resume",
                    "SID",
                    "--profile=restored",
                ]
            ) == "restored"
        )
        #expect(
            policy.selectedProfile(
                arguments: ["codex", "--profile", "resume", "fresh prompt"]
            ) == nil
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
                effectiveProjectDecisionPaths: []
            ) == [
                "-c",
                #"projects={"/Users/me/other-worktree"={trust_level="untrusted"}}"#,
            ]
        )
    }

    @Test("Working-directory parsing skips values consumed by other options")
    func workingDirectoryParsingSkipsOptionValues() {
        #expect(
            policy.effectiveWorkingDirectory(
                arguments: ["codex", "-c", "--cd", "resume", "SID"],
                currentDirectory: "/Users/me/worktree"
            ) == "/Users/me/worktree"
        )
        #expect(
            policy.effectiveWorkingDirectory(
                arguments: [
                    "codex",
                    "--model",
                    "-C",
                    "resume",
                    "SID",
                    "--cd",
                    "/Users/me/restored",
                ],
                currentDirectory: "/Users/me/worktree"
            ) == "/Users/me/restored"
        )
    }

    @Test("Effective config response extracts system and managed project decisions")
    func effectiveConfigResponseExtractsProjectDecisions() {
        let output = """
        {"id":1,"result":{"userAgent":"test"}}
        {"method":"config/changed","params":{}}
        {"id":2,"result":{"config":{"projects":{"/Users/me/system":{"trust_level":"trusted"},"/Users/me/managed":{"trust_level":"untrusted"},"relative":{"trust_level":"trusted"},"/Users/me/empty":{}}},"origins":{},"layers":null}}
        """
        #expect(
            policy.effectiveProjectDecisionPaths(appServerOutput: output) == [
                "/Users/me/system",
                "/Users/me/managed",
            ]
        )
    }

    @Test("Missing projects is a valid empty effective configuration")
    func effectiveConfigWithoutProjectsIsEmpty() {
        #expect(
            policy.effectiveProjectDecisionPaths(
                appServerOutput: #"{"id":2,"result":{"config":{},"origins":{},"layers":null}}"#
            ) == []
        )
    }

    @Test("Malformed and error responses fail closed")
    func invalidEffectiveConfigResponseFailsClosed() {
        #expect(
            policy.effectiveProjectDecisionPaths(
                appServerOutput: #"{"id":2,"error":{"code":-32603,"message":"failed"}}"#
            ) == nil
        )
        #expect(
            policy.effectiveProjectDecisionPaths(
                appServerOutput: #"{"id":2,"result":{"config":{"projects":[]},"origins":{}}}"#
            ) == nil
        )
        #expect(
            policy.effectiveProjectDecisionPaths(
                appServerOutput: #"{"id":2,"result":{"config":{"projects":{"/Users/me":{"trust_level":"future"}}}}}"#
            ) == nil
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
                effectiveProjectDecisionPaths: []
            ) == [
                "-c",
                #"projects={"\#(canonical)"={trust_level="untrusted"}}"#,
            ]
        )
    }

    @Test("Codex honors a decision for the logical symlink path")
    func logicalSymlinkDecisionRemainsAuthoritative() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-trust-\(UUID().uuidString)", isDirectory: true)
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fileManager.createDirectory(at: actual, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: actual)
        defer { try? fileManager.removeItem(at: root) }

        #expect(
            policy.undecidedProjectOverride(
                arguments: ["codex", "resume", "SID"],
                currentDirectory: alias.path,
                repositoryRoot: nil,
                effectiveProjectDecisionPaths: [alias.path]
            ).isEmpty
        )
    }

    @Test("macOS tmp alias resolves to the filesystem path Codex evaluates")
    func macOSTemporaryDirectoryAliasUsesPrivatePath() {
        #expect(
            policy.undecidedProjectOverride(
                arguments: ["codex", "resume", "SID"],
                currentDirectory: "/tmp",
                repositoryRoot: nil,
                effectiveProjectDecisionPaths: []
            ) == [
                "-c",
                #"projects={"/private/tmp"={trust_level="untrusted"}}"#,
            ]
        )
    }
}
