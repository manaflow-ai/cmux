import Foundation
import Testing
@testable import CmuxGit

@Suite struct WorkspaceChangesResourceBoundsTests {
    @Test func boundedSnapshotCommandPropagatesPartialResultAsTruncated() async {
        let root = "/tmp/cmux-truncated-snapshot"
        let statusArguments = ["diff", "-M", "--name-status", "-z", "HEAD", "--"]
        let runner = FakeWorkspaceChangesGitRunner(results: [
            ["rev-parse", "--show-toplevel"]: FakeWorkspaceChangesGitRunner.result("\(root)\n"),
            ["symbolic-ref", "--quiet", "--short", "HEAD"]: FakeWorkspaceChangesGitRunner.result("main\n"),
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
            statusArguments: WorkspaceChangesGitResult(
                output: Data("M\0File.swift\0".utf8),
                exitCode: 15,
                standardOutputWasTruncated: true
            ),
            ["diff", "-M", "--numstat", "-z", "HEAD", "--"]:
                FakeWorkspaceChangesGitRunner.result("4\t2\tFile.swift\0"),
            ["ls-files", "--others", "--exclude-standard", "-z"]:
                FakeWorkspaceChangesGitRunner.result(),
        ])

        let files = await WorkspaceChangesService(runner: runner)
            .changedFiles(forDirectory: root)

        #expect(files.isRepository)
        #expect(files.files.map(\.path) == ["File.swift"])
        #expect(files.truncated)
    }

    @Test func boundedSystemRunnerTerminatesAtWallDeadline() throws {
        let runner = SystemWorkspaceChangesGitRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            boundedCommandWallTimeLimit: 0.05
        )
        let clock = ContinuousClock()
        let start = clock.now

        let result = try runner.run(
            arguments: ["-c", "while :; do :; done"],
            in: FileManager.default.temporaryDirectory,
            maximumOutputByteCount: 1_024
        )

        #expect(result.standardOutputWasTruncated)
        #expect(clock.now - start < .seconds(2))
    }

    @Test func aggregateUntrackedBudgetSkipsUnreadableRemainder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-untracked-aggregate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("1\n2\n".utf8).write(to: root.appendingPathComponent("first.txt"))
        let inspector = WorkspaceUntrackedFileInspector(
            perFileReadByteCount: 4,
            aggregateReadByteCount: 4
        )

        let files = try #require(inspector.inspect(
            paths: ["first.txt", "missing.txt"],
            repoRoot: root.path
        ))

        #expect(files.map(\.path) == ["first.txt", "missing.txt"])
        #expect(files.map(\.additions) == [2, 0])
    }

    @Test func aggregateUntrackedInspectionObservesTaskCancellation() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let inspector = WorkspaceUntrackedFileInspector(
            perFileReadByteCount: 4,
            aggregateReadByteCount: 4
        )
        let task = Task {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            return inspector.inspect(
                paths: ["missing-after-cancel.txt"],
                repoRoot: FileManager.default.temporaryDirectory.path
            )
        }

        task.cancel()
        continuation.yield()
        continuation.finish()
        let files = await task.value

        #expect(files?.map(\.path) == ["missing-after-cancel.txt"])
        #expect(files?.map(\.additions) == [0])
    }
}
