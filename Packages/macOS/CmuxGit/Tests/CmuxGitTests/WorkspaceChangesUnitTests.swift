import Darwin
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

    @Test func contentReaderRejectsComponentSwappedToOutsideSymlinkAfterValidation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-content-root-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-content-outside-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("inside".utf8).write(to: directory.appendingPathComponent("secret.txt"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        let validatedPath = try WorkspaceChangesPathValidator().validatedPath(
            "nested/secret.txt",
            repoRoot: root.path
        )
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)

        #expect(throws: (any Error).self) {
            try WorkspaceChangesContentReader().fetch(
                repoRoot: root.path,
                relativePath: validatedPath,
                offset: 0,
                length: 1_024
            )
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

    @Test func forcedSummaryBypassesRepositoryRootCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-force-summary-\(UUID().uuidString)", isDirectory: true)
        let markers = root.appendingPathComponent("markers", isDirectory: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let statusArguments = ["diff", "-M", "--name-status", "-z", "abc", "--"]
        let runner = FakeWorkspaceChangesGitRunner(
            results: [
                ["rev-parse", "--show-toplevel"]:
                    FakeWorkspaceChangesGitRunner.result("\(root.path)\n"),
                ["symbolic-ref", "--quiet", "--short", "HEAD"]:
                    FakeWorkspaceChangesGitRunner.result("main\n"),
                ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]:
                    FakeWorkspaceChangesGitRunner.result(exitCode: 1),
                ["rev-parse", "--verify", "--quiet", "origin/main^{commit}"]:
                    FakeWorkspaceChangesGitRunner.result(exitCode: 1),
                ["rev-parse", "--verify", "--quiet", "origin/master^{commit}"]:
                    FakeWorkspaceChangesGitRunner.result(exitCode: 1),
                ["rev-parse", "--verify", "--quiet", "main^{commit}"]:
                    FakeWorkspaceChangesGitRunner.result("abc\n"),
                ["rev-parse", "--verify", "HEAD^{commit}"]:
                    FakeWorkspaceChangesGitRunner.result("abc\n"),
                statusArguments:
                    FakeWorkspaceChangesGitRunner.result("M\0File.swift\0"),
                ["diff", "-M", "--numstat", "-z", "abc", "--"]:
                    FakeWorkspaceChangesGitRunner.result("1\t1\tFile.swift\0"),
                ["ls-files", "--others", "--exclude-standard", "-z"]:
                    FakeWorkspaceChangesGitRunner.result(),
            ],
            beforeRun: { arguments, _ in
                guard arguments == statusArguments else { return }
                try Data().write(
                    to: markers.appendingPathComponent(UUID().uuidString)
                )
            }
        )
        let service = WorkspaceChangesService(runner: runner)

        _ = await service.summary(forDirectory: root.path)
        _ = await service.summary(forDirectory: root.path)
        _ = await service.summary(forDirectory: root.path, force: true)

        let captures = try FileManager.default.contentsOfDirectory(
            at: markers,
            includingPropertiesForKeys: nil
        )
        #expect(captures.count == 2)
    }

    @Test func serviceUsesInjectedRunnerAndParsers() async throws {
        let root = "/tmp/cmux-fake-repo"
        let runner = FakeWorkspaceChangesGitRunner(results: [
            ["rev-parse", "--show-toplevel"]: .init(output: Data("\(root)\n".utf8), exitCode: 0),
            ["symbolic-ref", "--quiet", "--short", "HEAD"]: FakeWorkspaceChangesGitRunner.result("feat\n"),
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/main^{commit}"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/master^{commit}"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "main^{commit}"]: FakeWorkspaceChangesGitRunner.result("abc\n"),
            ["merge-base", "HEAD", "main"]: FakeWorkspaceChangesGitRunner.result("base-sha\n"),
            ["rev-parse", "--verify", "base-sha^{commit}"]:
                FakeWorkspaceChangesGitRunner.result("resolved-base-oid\n"),
            ["diff", "-M", "--name-status", "-z", "resolved-base-oid", "--"]:
                FakeWorkspaceChangesGitRunner.result("M\0File.swift\0"),
            ["diff", "-M", "--numstat", "-z", "resolved-base-oid", "--"]:
                FakeWorkspaceChangesGitRunner.result("4\t2\tFile.swift\0"),
            ["ls-files", "--others", "--exclude-standard", "-z"]: FakeWorkspaceChangesGitRunner.result(),
        ])

        let files = try await WorkspaceChangesService(runner: runner).changedFiles(forDirectory: root)

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

    @Test func streamedSnapshotCapsFarLargerInputButKeepsFullTotals() async throws {
        let root = "/tmp/cmux-fake-large-repo"
        let paths = (0..<2_000).map { String(format: "File-%04d.swift", $0) }
        let reversePaths = paths.reversed()
        let statuses = reversePaths.map { "M\0\($0)\0" }.joined()
        let numstat = reversePaths.map { "1\t2\t\($0)\0" }.joined()
        let runner = FakeWorkspaceChangesGitRunner(results: [
            ["rev-parse", "--show-toplevel"]: FakeWorkspaceChangesGitRunner.result("\(root)\n"),
            ["symbolic-ref", "--quiet", "--short", "HEAD"]: FakeWorkspaceChangesGitRunner.result("main\n"),
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/main^{commit}"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/master^{commit}"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "main^{commit}"]: FakeWorkspaceChangesGitRunner.result("abc\n"),
            ["rev-parse", "--verify", "HEAD^{commit}"]: FakeWorkspaceChangesGitRunner.result("abc\n"),
            ["diff", "-M", "--name-status", "-z", "abc", "--"]:
                FakeWorkspaceChangesGitRunner.result(statuses),
            ["diff", "-M", "--numstat", "-z", "abc", "--"]:
                FakeWorkspaceChangesGitRunner.result(numstat),
            ["ls-files", "--others", "--exclude-standard", "-z"]: FakeWorkspaceChangesGitRunner.result(),
        ])

        let files = try await WorkspaceChangesService(runner: runner).changedFiles(forDirectory: root)

        #expect(files.files.count == 500)
        #expect(files.files.first?.path == "File-0000.swift")
        #expect(files.files.last?.path == "File-0499.swift")
        #expect(files.filesChanged == 2_000)
        #expect(files.additions == 2_000)
        #expect(files.deletions == 4_000)
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

    @Test func splitsCRLFLinesForCountingAndTruncation() {
        // Git diffs of CRLF files end every content line with "\r\n". The
        // truncator must break at those boundaries: a Character split treats
        // "\r\n" as one grapheme, collapses whole CRLF hunks into a single
        // mega-line, undercounts totals, and hides interior hunk headers.
        let fileHeader = [
            "diff --git a/Windows.txt b/Windows.txt",
            "index 1111111..2222222 100644",
            "--- a/Windows.txt",
            "+++ b/Windows.txt",
        ]
        let hunk1 = ["@@ -1,2 +1,2 @@", "-old one\r", "+new one\r", " same\r"]
        let hunk2 = ["@@ -10,2 +10,2 @@", "-old two\r", "+new two\r", " tail\r"]
        let diff = (fileHeader + hunk1 + hunk2).joined(separator: "\n")

        let full = WorkspaceDiffTruncator().truncate(diff)
        #expect(full.totalLineCount == 12)

        let bounded = WorkspaceDiffTruncator(maximumBytes: 1 << 20, maximumLines: 9)
            .truncate(diff)
        #expect(bounded.truncated)
        // Compare split lines: Character-based contains/hasSuffix cannot see
        // a trailing "\r" that the neighboring "\n" fuses into one grapheme.
        let boundedLines = bounded.text.components(separatedBy: "\n")
        #expect(boundedLines.last == " same\r")
        #expect(boundedLines.contains("+new one\r"))
        #expect(!bounded.text.contains("old two"))
    }

    @Test func progressiveDiffBudgetClampsToResponseAbuseGuard() {
        let bounded = WorkspaceDiffTruncator(requestedMaximumLines: Int.max)

        #expect(bounded.maximumLines == 1_000_000)
        #expect(bounded.maximumBytes == 6 * 1024 * 1024)
        #expect(bounded.maximumInputBytes == 13 * 1024 * 1024)
    }

    @Test func boundedSystemRunnerStopsAtItsOutputLimit() throws {
        let runner = SystemWorkspaceChangesGitRunner(
            executableURL: URL(fileURLWithPath: "/bin/echo")
        )

        let result = try runner.run(
            arguments: [String(repeating: "x", count: 4_096)],
            in: FileManager.default.temporaryDirectory,
            maximumOutputByteCount: 257
        )

        #expect(result.output.count == 257)
        #expect(result.standardOutputWasTruncated)
    }

    @Test func untrackedInspectorCountsSmallTextWithoutGit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-untracked-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one\ntwo\nthree\n".utf8).write(to: root.appendingPathComponent("new.txt"))

        let file = try #require(WorkspaceUntrackedFileInspector().inspect(
            path: "new.txt",
            repoRoot: root.path
        ))

        #expect(file.additions == 3)
        #expect(file.deletions == 0)
        #expect(!file.isBinary)
    }

    @Test func untrackedInspectorSkipsSymlinkWithoutReadingOutsideRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-untracked-link-root-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-untracked-link-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let outsideFile = outside.appendingPathComponent("secret.txt")
        try Data("outside\nmust\nnot\nbe\nread\n".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.txt"),
            withDestinationURL: outsideFile
        )
        let inspector = WorkspaceUntrackedFileInspector()

        let files = try #require(inspector.inspect(
            paths: ["linked.txt"],
            repoRoot: root.path
        ))

        #expect(inspector.inspect(path: "linked.txt", repoRoot: root.path) == nil)
        #expect(files.map(\.path) == ["linked.txt"])
        #expect(files.map(\.additions) == [0])
    }

    @Test func untrackedInspectorRejectsNonRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-untracked-fifo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("events.pipe")
        let createResult = fifo.path.withCString { Darwin.mkfifo($0, 0o600) }
        #expect(createResult == 0)
        let inspector = WorkspaceUntrackedFileInspector()

        let files = try #require(inspector.inspect(
            paths: ["events.pipe"],
            repoRoot: root.path
        ))

        #expect(inspector.inspect(path: "events.pipe", repoRoot: root.path) == nil)
        #expect(files.map(\.additions) == [0])
    }

    @Test func fileCapPrecedesUntrackedInspectionAndPerFileGitWork() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-capped-untracked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let paths = (0..<500).map { String(format: "File-%03d.swift", $0) }
        let statuses = paths.map { "M\0\($0)\0" }.joined()
        let numstat = paths.map { "1\t2\t\($0)\0" }.joined()
        let runner = FakeWorkspaceChangesGitRunner(results: [
            ["rev-parse", "--show-toplevel"]: FakeWorkspaceChangesGitRunner.result("\(rootURL.path)\n"),
            ["symbolic-ref", "--quiet", "--short", "HEAD"]: FakeWorkspaceChangesGitRunner.result("main\n"),
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/main^{commit}"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/master^{commit}"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "main^{commit}"]: FakeWorkspaceChangesGitRunner.result("abc\n"),
            ["rev-parse", "--verify", "HEAD^{commit}"]: FakeWorkspaceChangesGitRunner.result("abc\n"),
            ["diff", "-M", "--name-status", "-z", "abc", "--"]:
                FakeWorkspaceChangesGitRunner.result(statuses),
            ["diff", "-M", "--numstat", "-z", "abc", "--"]:
                FakeWorkspaceChangesGitRunner.result(numstat),
            ["ls-files", "--others", "--exclude-standard", "-z"]: FakeWorkspaceChangesGitRunner.result("zzz-untracked.txt\0"),
        ])

        let files = try await WorkspaceChangesService(runner: runner)
            .changedFiles(forDirectory: rootURL.path)

        // The injected runner rejects every unconfigured command, including
        // the old per-file `git diff --no-index` fanout.
        #expect(files.isRepository)
        #expect(files.files.count == 500)
        #expect(files.filesChanged == 501)
        #expect(files.truncated)
    }
}
