import Darwin
import Foundation
import Testing
@testable import CmuxGit

@Suite struct WorkspaceChangesResourceBoundsTests {
    @Test func boundedSnapshotCommandPropagatesPartialResultAsTruncated() async throws {
        let root = "/tmp/cmux-truncated-snapshot"
        let statusArguments = ["diff", "-M", "--name-status", "-z", "abc", "--"]
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
            ["diff", "-M", "--numstat", "-z", "abc", "--"]:
                FakeWorkspaceChangesGitRunner.result("4\t2\tFile.swift\0"),
            ["ls-files", "--others", "--exclude-standard", "-z"]:
                FakeWorkspaceChangesGitRunner.result(),
        ])

        let files = try await WorkspaceChangesService(runner: runner)
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
        #expect(clock.now - start < .seconds(4))
    }

    @Test func plainSystemRunnerTerminatesAtWallDeadline() throws {
        let runner = SystemWorkspaceChangesGitRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            boundedCommandWallTimeLimit: 0.05
        )
        let clock = ContinuousClock()
        let start = clock.now

        let result = try runner.run(
            arguments: ["-c", "while :; do :; done"],
            in: FileManager.default.temporaryDirectory
        )

        #expect(result.standardOutputWasTruncated)
        #expect(clock.now - start < .seconds(4))
    }

    @Test func cappedReadDoesNotWaitForGraceAfterCooperativeChildExits() throws {
        let runner = SystemWorkspaceChangesGitRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            boundedCommandWallTimeLimit: 10
        )
        let clock = ContinuousClock()
        let start = clock.now

        let result = try runner.run(
            arguments: [],
            in: FileManager.default.temporaryDirectory,
            maximumOutputByteCount: 1
        )

        #expect(result.standardOutputWasTruncated)
        #expect(clock.now - start < .seconds(2))
    }

    @Test func hardDeadlineKillsTermIgnoringProcessGroupWithinGrace() throws {
        let runner = SystemWorkspaceChangesGitRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            boundedCommandWallTimeLimit: 0.05
        )
        let clock = ContinuousClock()
        let start = clock.now

        let result = try runner.run(
            arguments: [
                "-c",
                "(trap '' TERM; while :; do :; done) & wait",
            ],
            in: FileManager.default.temporaryDirectory,
            maximumOutputByteCount: 1_024
        )

        #expect(result.standardOutputWasTruncated)
        #expect(clock.now - start < .seconds(4))
    }

    @Test func hardDeadlineReapsDescendantHoldingStandardOutputAfterLeaderExit() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-descendant-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let runner = SystemWorkspaceChangesGitRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            boundedCommandWallTimeLimit: 0.1
        )
        let clock = ContinuousClock()
        let start = clock.now

        let result = try runner.run(
            arguments: [
                "-c",
                "exec sleep 60 & echo $! > \(pidFile.path)",
            ],
            in: FileManager.default.temporaryDirectory,
            maximumOutputByteCount: 1_024
        )

        let descendantPID = try #require(pid_t(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        errno = 0
        let probeResult = Darwin.kill(descendantPID, 0)

        #expect(result.standardOutputWasTruncated)
        #expect(clock.now - start < .seconds(4))
        #expect(probeResult == -1)
        #expect(errno == ESRCH)
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
        #expect(files.map(\.isBinary) == [false, true])
        #expect(files.map(\.isApproximate) == [false, true])
    }

    @Test func cappedUntrackedCountMarksFileAndSnapshotPartial() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-untracked-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent("partial.txt"))
        let runner = FakeWorkspaceChangesGitRunner(results: [
            ["diff", "-M", "--name-status", "-z", "abc", "--"]:
                FakeWorkspaceChangesGitRunner.result(),
            ["diff", "-M", "--numstat", "-z", "abc", "--"]:
                FakeWorkspaceChangesGitRunner.result(),
            ["ls-files", "--others", "--exclude-standard", "-z"]:
                FakeWorkspaceChangesGitRunner.result("partial.txt\0"),
        ])
        let loader = WorkspaceChangesSnapshotLoader(
            runner: runner,
            untrackedInspector: WorkspaceUntrackedFileInspector(
                perFileReadByteCount: 4,
                aggregateReadByteCount: 4
            )
        )
        let scope = WorkspaceChangesScope(
            repoRoot: root.path,
            branch: "main",
            baseRef: nil,
            diffBase: "abc",
            diffBaseCommitOID: "abc"
        )

        let snapshot = try loader.loadSnapshot(scope: scope)
        let file = try #require(snapshot.files.first)
        let response = WorkspaceChangesService(runner: runner)
            .changedFilesValue(from: snapshot)

        #expect(file.additions == 1)
        #expect(file.isApproximate)
        #expect(snapshot.truncated)
        #expect(response.files.first?.isApproximate == true)
        #expect(response.truncated)
    }

    @Test func exhaustedLineBudgetStillClassifiesBinaryPrefix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-untracked-classification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("done".utf8).write(to: root.appendingPathComponent("first.txt"))
        try Data([0x41, 0x00, 0x42]).write(to: root.appendingPathComponent("second.bin"))
        let inspector = WorkspaceUntrackedFileInspector(
            perFileReadByteCount: 4,
            aggregateReadByteCount: 4
        )

        let files = try #require(inspector.inspect(
            paths: ["first.txt", "second.bin"],
            repoRoot: root.path
        ))

        #expect(files.map(\.additions) == [1, 0])
        #expect(files.map(\.isBinary) == [false, true])
        #expect(files.map(\.isApproximate) == [false, false])
    }

    @Test func exhaustedClassificationBudgetFallsBackToBinary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-untracked-safe-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("plain text\n".utf8).write(to: root.appendingPathComponent("unprobed.txt"))
        let inspector = WorkspaceUntrackedFileInspector(
            aggregateReadByteCount: 0,
            aggregateClassificationByteCount: 0
        )

        let files = try #require(inspector.inspect(
            paths: ["unprobed.txt"],
            repoRoot: root.path
        ))

        #expect(files.first?.additions == 0)
        #expect(files.first?.isBinary == true)
        #expect(files.first?.isApproximate == true)
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
        #expect(files?.map(\.isBinary) == [true])
        #expect(files?.map(\.isApproximate) == [true])
    }
}
