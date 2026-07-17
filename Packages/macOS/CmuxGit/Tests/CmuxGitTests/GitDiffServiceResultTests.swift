import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitDiffServiceResultTests {
    @Test func repositoryRootResultPreservesTimeout() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let stalledGit = repo.appendingPathComponent("stalled-root-git.sh")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: stalledGit)
        try makeExecutable(stalledGit)
        let service = GitDiffService(
            gitExecutableURL: stalledGit,
            processDeadlineSeconds: 0.1
        )

        switch service.repositoryRootResult(for: repo.path) {
        case .timedOut:
            break
        default:
            Issue.record("A Git timeout was flattened into another root lookup result")
        }
    }

    @Test func fileDiffResultPreservesGitExecutionFailure() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("changed\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        let failingGit = repo.appendingPathComponent("failing-file-git.sh")
        try Data("#!/bin/sh\nexit 2\n".utf8).write(to: failingGit)
        try makeExecutable(failingGit)
        let service = GitDiffService(gitExecutableURL: failingGit)

        switch service.fileDiffResult(repoRoot: repo.path, path: "a.txt") {
        case .failed:
            break
        default:
            Issue.record("A Git execution failure was flattened into a missing file")
        }
    }

    @Test func changedFilesResultPreservesStatusTimeout() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let stalledGit = repo.appendingPathComponent("stalled-status-git.sh")
        try Data(
            "#!/bin/sh\nif [ \"$3\" = rev-parse ]; then echo HEAD; exit 0; fi\nsleep 30\n".utf8
        ).write(to: stalledGit)
        try makeExecutable(stalledGit)
        let service = GitDiffService(
            gitExecutableURL: stalledGit,
            processDeadlineSeconds: 0.1
        )

        switch service.changedFilesResult(repoRoot: repo.path) {
        case .timedOut:
            break
        default:
            Issue.record("A status-phase timeout was flattened into a generic Git failure")
        }
    }

    @Test func changedFilesPipelineUsesOneAggregateDeadlineAcrossCommands() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let trackedFile = repo.appendingPathComponent("tracked.txt")
        try Data("original\n".utf8).write(to: trackedFile)
        try runTestGit(in: repo, ["add", "--", "tracked.txt"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add tracked file"])
        try Data("changed\n".utf8).write(to: trackedFile)

        let invocationLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-listing-invocations-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: invocationLog) }
        let delayedGit = repo.appendingPathComponent("delayed-git.sh")
        try Data(
            "#!/bin/sh\ndelayed=0\nfor argument do\n  case \"$argument\" in\n    --numstat|--name-status|--others|--raw) delayed=1 ;;\n  esac\ndone\nif [ \"$delayed\" = 1 ]; then\n  printf 'listing\\n' >> \(invocationLog.path.debugDescription)\n  /bin/sleep 0.12\nfi\nexec /usr/bin/git \"$@\"\n".utf8
        ).write(to: delayedGit)
        try makeExecutable(delayedGit)
        let service = GitDiffService(
            gitExecutableURL: delayedGit,
            processDeadlineSeconds: 0.35,
            operationDeadlineSeconds: 0.35
        )
        let clock = ContinuousClock()
        let started = clock.now

        let result = service.changedFilesResult(repoRoot: repo.path)
        let elapsed = started.duration(to: clock.now)
        let invocationCount = ((try? String(contentsOf: invocationLog, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .count

        switch result {
        case .timedOut:
            break
        case .success:
            Issue.record(
                "The pipeline completed \(invocationCount) sequential listings in \(elapsed) by resetting the deadline"
            )
            return
        case .failed, .notFound:
            Issue.record("The delayed listing fixture failed before exercising the aggregate deadline")
            return
        }
        #expect(
            elapsed < .seconds(5),
            "The pipeline continued running after its aggregate deadline: \(elapsed)"
        )
        #expect(
            invocationCount <= 4,
            "The pipeline started \(invocationCount) Git listings after its shared budget should have stopped it"
        )
    }

    @Test func fileDiffSnapshotValidationPreservesFailure() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = "tracked.txt"
        let trackedFile = repo.appendingPathComponent(path)
        try Data("original\n".utf8).write(to: trackedFile)
        try runTestGit(in: repo, ["add", "--", path])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add tracked file"])
        try Data("changed\n".utf8).write(to: trackedFile)
        let visible = try #require(
            GitDiffService().changedFiles(repoRoot: repo.path)?.files.first
        )
        let scopedNumstatCount = repo.appendingPathComponent("scoped-numstat-count")
        let failingGit = repo.appendingPathComponent("failing-snapshot-git.sh")
        try Data(
            "#!/bin/sh\nscoped=0\nnumstat=0\nfor argument do\n  if [ \"$argument\" = ':(literal)tracked.txt' ]; then scoped=1; fi\n  if [ \"$argument\" = '--numstat' ]; then numstat=1; fi\ndone\nif [ \"$scoped:$numstat\" = '1:1' ]; then\n  count=0\n  if [ -f \(scopedNumstatCount.path.debugDescription) ]; then count=$(cat \(scopedNumstatCount.path.debugDescription)); fi\n  count=$((count + 1))\n  printf '%s' \"$count\" > \(scopedNumstatCount.path.debugDescription)\n  if [ \"$count\" -ge 2 ]; then exit 2; fi\nfi\nexec /usr/bin/git \"$@\"\n".utf8
        ).write(to: failingGit)
        try makeExecutable(failingGit)
        let service = GitDiffService(gitExecutableURL: failingGit)

        let result = service.fileDiffResult(
            repoRoot: repo.path,
            path: visible.path,
            oldPath: visible.oldPath,
            status: visible.status,
            additions: visible.additions,
            deletions: visible.deletions,
            snapshotToken: visible.snapshotToken
        )

        guard case .failed = result else {
            Issue.record("Snapshot validation flattened a Git failure into \(result)")
            return
        }
    }

    private func makeTempRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-diff-result-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for arguments in [
            ["init", "--quiet"],
            ["config", "user.email", "tests@cmux.dev"],
            ["config", "user.name", "cmux tests"],
            ["commit", "--allow-empty", "--quiet", "-m", "init"],
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        return root
    }

    private func runTestGit(in root: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }
}
