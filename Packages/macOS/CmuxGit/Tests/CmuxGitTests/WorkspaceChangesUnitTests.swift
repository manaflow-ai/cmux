import Foundation
import Testing
@testable import CmuxGit

@Suite struct WorkspaceChangesUnitTests {
    @MainActor
    @Test func nonisolatedServiceMethodsRunOffMainThread() async {
        #expect(await WorkspaceChangesService().executionHopsOffCallersThread())
    }

    @Test func parsesNameStatusIncludingRename() {
        let data = Data("M\0Sources/A.swift\0R100\0Old.swift\0New.swift\0D\0Gone.swift\0".utf8)

        let entries = WorkspaceChangesParser().nameStatusEntries(from: data)

        #expect(entries == [
            .init(path: "Sources/A.swift", oldPath: nil, status: .modified),
            .init(path: "New.swift", oldPath: "Old.swift", status: .renamed),
            .init(path: "Gone.swift", oldPath: nil, status: .deleted),
        ])
    }

    @Test func parsesNumstatIncludingRenameAndBinary() {
        let data = Data("12\t3\tSources/A.swift\0-\t-\tBinary.dat\05\t1\t\0Old.swift\0New.swift\0".utf8)

        let entries = WorkspaceChangesParser().numstatEntries(from: data)

        #expect(entries == [
            .init(path: "Sources/A.swift", additions: 12, deletions: 3, isBinary: false),
            .init(path: "Binary.dat", additions: 0, deletions: 0, isBinary: true),
            .init(path: "New.swift", additions: 5, deletions: 1, isBinary: false),
        ])
    }

    @Test func validatorNormalizesInternalDotDotAndRejectsEscapes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-path-validator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let validator = WorkspaceChangesPathValidator()

        #expect(try validator.validatedPath("Sources/../README.md", repoRoot: root.path) == "README.md")
        #expect(throws: WorkspaceChangesServiceError.invalidPath) {
            try validator.validatedPath("../outside", repoRoot: root.path)
        }
        #expect(throws: WorkspaceChangesServiceError.invalidPath) {
            try validator.validatedPath("/etc/passwd", repoRoot: root.path)
        }
    }

    @Test func validatorRejectsSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-path-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside"),
            withDestinationURL: root.deletingLastPathComponent()
        )

        #expect(throws: WorkspaceChangesServiceError.invalidPath) {
            try WorkspaceChangesPathValidator().validatedPath("outside/secret", repoRoot: root.path)
        }
    }

    @Test func summaryCacheExpiresUsingInjectedClock() async {
        let clock = TestWorkspaceChangesClock()
        let cache = WorkspaceChangesSummaryCache(ttl: .seconds(15), clock: clock)
        let summary = WorkspaceChangesSummary(
            isRepository: true,
            repoRoot: "/repo",
            branch: "feat",
            baseRef: "main",
            filesChanged: 1,
            additions: 2,
            deletions: 3
        )
        await cache.store(summary, forRepoRoot: "/repo")

        #expect(await cache.summary(forRepoRoot: "/repo") == summary)
        await clock.advance(by: .seconds(14))
        #expect(await cache.summary(forRepoRoot: "/repo") == summary)
        await clock.advance(by: .seconds(2))
        #expect(await cache.summary(forRepoRoot: "/repo") == nil)
    }

    @Test func serviceUsesInjectedRunnerAndParsers() async {
        let root = "/tmp/cmux-fake-repo"
        let runner = FakeWorkspaceChangesGitRunner(results: [
            ["rev-parse", "--show-toplevel"]: .init(output: Data("\(root)\n".utf8), exitCode: 0),
            ["symbolic-ref", "--quiet", "--short", "HEAD"]: FakeWorkspaceChangesGitRunner.result("feat\n"),
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/main^{commit}"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/master^{commit}"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "main^{commit}"]: FakeWorkspaceChangesGitRunner.result("abc\n"),
            ["merge-base", "HEAD", "main"]: FakeWorkspaceChangesGitRunner.result("base-sha\n"),
            ["diff", "-M", "--name-status", "-z", "base-sha", "--"]: FakeWorkspaceChangesGitRunner.result("M\0File.swift\0"),
            ["diff", "-M", "--numstat", "-z", "base-sha", "--"]: FakeWorkspaceChangesGitRunner.result("4\t2\tFile.swift\0"),
            ["ls-files", "--others", "--exclude-standard", "-z"]: FakeWorkspaceChangesGitRunner.result(),
        ])

        let files = await WorkspaceChangesService(runner: runner).changedFiles(forDirectory: root)

        #expect(files.baseRef == "main")
        #expect(files.files == [
            WorkspaceChangedFile(
                path: "File.swift",
                oldPath: nil,
                status: .modified,
                additions: 4,
                deletions: 2,
                isBinary: false
            )
        ])
    }

    @Test func changedFilesCapsListButKeepsFullTotals() async {
        let root = "/tmp/cmux-fake-large-repo"
        let paths = (0..<501).map { String(format: "File-%03d.swift", $0) }
        let statuses = paths.map { "M\0\($0)\0" }.joined()
        let numstat = paths.map { "1\t2\t\($0)\0" }.joined()
        let runner = FakeWorkspaceChangesGitRunner(results: [
            ["rev-parse", "--show-toplevel"]: FakeWorkspaceChangesGitRunner.result("\(root)\n"),
            ["symbolic-ref", "--quiet", "--short", "HEAD"]: FakeWorkspaceChangesGitRunner.result("main\n"),
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/main^{commit}"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/master^{commit}"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "main^{commit}"]: FakeWorkspaceChangesGitRunner.result("abc\n"),
            ["diff", "-M", "--name-status", "-z", "HEAD", "--"]: FakeWorkspaceChangesGitRunner.result(statuses),
            ["diff", "-M", "--numstat", "-z", "HEAD", "--"]: FakeWorkspaceChangesGitRunner.result(numstat),
            ["ls-files", "--others", "--exclude-standard", "-z"]: FakeWorkspaceChangesGitRunner.result(),
        ])

        let files = await WorkspaceChangesService(runner: runner).changedFiles(forDirectory: root)

        #expect(files.files.count == 500)
        #expect(files.filesChanged == 501)
        #expect(files.additions == 501)
        #expect(files.deletions == 1_002)
        #expect(files.truncated)
    }

    @Test func truncatesInsideAnOversizedSingleHunk() {
        let fileHeader = [
            "diff --git a/Big.swift b/Big.swift",
            "index 1111111..2222222 100644",
            "--- a/Big.swift",
            "+++ b/Big.swift",
        ]
        let hunkHeader = "@@ -1,300 +1,300 @@"
        let body = (1...300).map { "-old line \($0)" } + (1...300).map { "+new line \($0)" }
        let diff = (fileHeader + [hunkHeader] + body).joined(separator: "\n")

        let bounded = WorkspaceDiffTruncator(maximumBytes: 1 << 20, maximumLines: 100).truncate(diff)

        #expect(bounded.truncated)
        let lines = bounded.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(lines.count <= 100)
        let hunkStart = lines.firstIndex { $0.hasPrefix("@@") }
        // A single hunk larger than the cap must yield a partial hunk, not a
        // contentless header-only diff.
        #expect(hunkStart != nil)
        guard let hunkStart else { return }
        let included = Array(lines[(hunkStart + 1)...])
        #expect(!included.isEmpty)
        let old = included.filter { $0.hasPrefix("-") || $0.hasPrefix(" ") }.count
        let new = included.filter { $0.hasPrefix("+") || $0.hasPrefix(" ") }.count
        // The rewritten header must describe exactly the included body.
        #expect(lines[hunkStart] == "@@ -1,\(old) +1,\(new) @@")
    }
}
