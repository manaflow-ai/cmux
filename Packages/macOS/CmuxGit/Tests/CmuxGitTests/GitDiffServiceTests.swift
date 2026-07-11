import Darwin
import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitDiffServiceTests {
    @Test func mergesSeparateNumstatAndNameStatusStreams() {
        let service = GitDiffService()
        let files = service.parseChangedFiles(
            numstatOutput: "3\t1\tSources/App.swift\0-\t-\tAssets/image.png\0",
            nameStatusOutput: "M\0Sources/App.swift\0A\0Assets/image.png\0",
            untrackedOutput: nil
        )

        #expect(files.count == 2)
        let app = try! #require(files.first { $0.path == "Sources/App.swift" })
        #expect(app.status == .modified)
        #expect(app.additions == 3)
        #expect(app.deletions == 1)

        let binary = try! #require(files.first { $0.path == "Assets/image.png" })
        #expect(binary.status == .added)
        #expect(binary.additions == nil)
        #expect(binary.deletions == nil)
    }

    @Test func mergesRenameNumstatAndNameStatusStreams() {
        let service = GitDiffService()
        let files = service.parseChangedFiles(
            numstatOutput: "2\t4\t\0Old.swift\0New.swift\0",
            nameStatusOutput: "R100\0Old.swift\0New.swift\0",
            untrackedOutput: nil
        )

        let renamed = try! #require(files.first)
        #expect(files.count == 1)
        #expect(renamed.path == "New.swift")
        #expect(renamed.oldPath == "Old.swift")
        #expect(renamed.status == .renamed)
        #expect(renamed.additions == 2)
        #expect(renamed.deletions == 4)
    }

    @Test func addsUntrackedFilesWithoutCounts() {
        let service = GitDiffService()
        let files = service.parseChangedFiles(
            numstatOutput: "",
            nameStatusOutput: "",
            untrackedOutput: "Scratch.md\0"
        )

        let untracked = try! #require(files.first)
        #expect(untracked.path == "Scratch.md")
        #expect(untracked.status == .untracked)
        #expect(untracked.additions == nil)
        #expect(untracked.deletions == nil)
    }

    @Test func untrackedLeadingDashPathDiffs() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dashName = "-flag.swift"
        try Data("let flagged = true\n".utf8)
            .write(to: repo.appendingPathComponent(dashName))

        let service = GitDiffService()
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: dashName))

        #expect(diff.path == dashName)
        #expect(diff.unifiedDiff.contains("+let flagged = true"))
    }

    @Test func untrackedBareDashPathDiffs() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dashName = "-"
        try Data("bare dash\n".utf8)
            .write(to: repo.appendingPathComponent(dashName))

        let service = GitDiffService()
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: dashName))

        #expect(diff.path == dashName)
        #expect(diff.unifiedDiff.contains("+bare dash"))
    }

    @Test func fileDiffOutputIsBoundedByMaxOutputBytes() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let line = "let payload = \"" + String(repeating: "x", count: 120) + "\"\n"
        let huge = String(repeating: line, count: 8_000)
        try Data(huge.utf8).write(to: repo.appendingPathComponent("Huge.swift"))

        let service = GitDiffService()
        let cap = 64 * 1024
        let diff = try #require(
            service.fileDiff(repoRoot: repo.path, path: "Huge.swift", maxOutputBytes: cap)
        )

        #expect(diff.unifiedDiff.utf8.count <= cap)
        // The bounded prefix keeps enough content for the caller's own
        // truncation detection (the full diff far exceeds the cap).
        #expect(diff.unifiedDiff.utf8.count > cap / 2)
        #expect(diff.unifiedDiff.contains("+let payload"))
        #expect(diff.truncated)
    }

    @Test func untrackedLeadingWhitespacePathDiffsVerbatim() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let spacedName = " leading-space.txt"
        try Data("padded name\n".utf8)
            .write(to: repo.appendingPathComponent(spacedName))

        let service = GitDiffService()
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: spacedName))

        #expect(diff.path == spacedName)
        #expect(diff.unifiedDiff.contains("+padded name"))
    }

    @Test func fileDiffBelowMaxOutputBytesIsUnaffected() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("small change\n".utf8).write(to: repo.appendingPathComponent("Small.txt"))

        let service = GitDiffService()
        let unbounded = try #require(service.fileDiff(repoRoot: repo.path, path: "Small.txt"))
        let bounded = try #require(
            service.fileDiff(repoRoot: repo.path, path: "Small.txt", maxOutputBytes: 64 * 1024)
        )

        #expect(bounded == unbounded)
    }

    @Test func trackedGlobCharacterFilenameDiffsExactly() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let globName = "file[1].txt"
        let fileURL = repo.appendingPathComponent(globName)
        try Data("original\n".utf8).write(to: fileURL)
        try runTestGit(in: repo, ["add", "--", globName])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add glob file"])
        try Data("changed\n".utf8).write(to: fileURL)

        let service = GitDiffService()
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: globName))

        // Without `:(literal)` the pathspec's `[1]` parses as a character
        // class and matches nothing, yielding an empty diff for a real file.
        #expect(diff.unifiedDiff.contains("+changed"))
    }

    @Test func externalDiffDriverIsBypassedForMachineReadableOutput() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let fileURL = repo.appendingPathComponent("driven.txt")
        try Data("original\n".utf8).write(to: fileURL)
        try runTestGit(in: repo, ["add", "--", "driven.txt"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add driven"])
        try Data("changed\n".utf8).write(to: fileURL)
        // A configured external diff driver would replace the unified format
        // (and execute an arbitrary tool) unless the service disables it.
        try runTestGit(in: repo, ["config", "diff.external", "echo EXTERNAL"])

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_EXTERNAL_DIFF"] = "echo EXTERNAL"
        let service = GitDiffService(environment: environment)
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: "driven.txt"))
        let changed = try #require(service.changedFiles(repoRoot: repo.path))
        let summary = try #require(changed.files.first { $0.path == "driven.txt" })

        #expect(diff.unifiedDiff.contains("+changed"))
        #expect(!diff.unifiedDiff.contains("EXTERNAL"))
        #expect(summary.additions == 1)
        #expect(summary.deletions == 1)
    }

    @Test func directoryShapedFileDiffRequestIsRejected() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let sub = repo.appendingPathComponent("generated")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for index in 0..<300 {
            try Data("x\n".utf8).write(to: sub.appendingPathComponent("f-\(1000 + index).txt"))
        }

        let service = GitDiffService()
        // The API is single-file: a directory pathspec would expand into a
        // combined multi-file diff, so it is rejected outright (and the byte
        // bound keeps the untracked probe from materializing the whole tree
        // in any case).
        #expect(service.fileDiff(repoRoot: repo.path, path: "generated", maxOutputBytes: 1024) == nil)
        #expect(service.fileDiff(repoRoot: repo.path, path: ".", maxOutputBytes: 1024) == nil)

        // A deleted file no longer exists on disk and must still diff.
        let tracked = repo.appendingPathComponent("kept.txt")
        try Data("kept\n".utf8).write(to: tracked)
        try runTestGit(in: repo, ["add", "--", "kept.txt"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add kept"])
        try FileManager.default.removeItem(at: tracked)
        let deleted = try #require(service.fileDiff(repoRoot: repo.path, path: "kept.txt"))
        #expect(deleted.unifiedDiff.contains("-kept"))
    }

    @Test func changedFilesListIsBoundedAndMarkedTruncated() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        for index in 0..<500 {
            try Data("x\n".utf8)
                .write(to: repo.appendingPathComponent("untracked-\(1000 + index).txt"))
        }

        let service = GitDiffService()
        let unbounded = try #require(service.changedFiles(repoRoot: repo.path))
        #expect(unbounded.files.count == 500)
        #expect(!unbounded.truncated)

        let bounded = try #require(service.changedFiles(repoRoot: repo.path, maxOutputBytes: 2048))
        #expect(bounded.truncated)
        #expect(!bounded.files.isEmpty)
        #expect(bounded.files.count < 500)
        // The byte cap must only ever drop whole records: every surviving
        // path is complete, never a prefix cut mid-filename.
        #expect(bounded.files.allSatisfy { $0.path.hasSuffix(".txt") })
    }

    @Test func unbornRepositoryIncludesStagedFileAndDiff() throws {
        let repo = try makeUnbornTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = "Initial.swift"
        try Data("let initial = true\n".utf8).write(to: repo.appendingPathComponent(path))
        try runTestGit(in: repo, ["add", "--", path])

        let service = GitDiffService()
        let changed = try #require(service.changedFiles(repoRoot: repo.path))
        let file = try #require(changed.files.first { $0.path == path })
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: path))

        #expect(file.status == .added)
        #expect(file.additions == 1)
        #expect(diff.unifiedDiff.contains("+let initial = true"))
    }

    @Test func deadlineEscalatesWhenGitIgnoresTerminationAndChildKeepsPipeOpen() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let stalledGit = repo.appendingPathComponent("term-ignoring-git.sh")
        try Data("#!/bin/sh\ntrap '' TERM\nsleep 3 &\nwait\n".utf8).write(to: stalledGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stalledGit.path
        )

        let service = GitDiffService(
            gitExecutableURL: stalledGit,
            processDeadlineSeconds: 0.1
        )
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = service.repositoryRoot(for: repo.path)
            finished.signal()
        }

        #expect(finished.wait(timeout: .now() + 1) == .success)
    }

    @Test func cancelledTaskSpawnsNoGitWork() async throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("x\n".utf8).write(to: repo.appendingPathComponent("a.txt"))

        let service = GitDiffService()
        let sendableRepoPath = repo.path
        let task = Task.detached {
            // Wait until cancelled before starting, so every runGit sees the
            // cancelled task and bails instead of spawning a subprocess.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return service.changedFiles(repoRoot: sendableRepoPath)
        }
        task.cancel()
        let result = await task.value

        // Cancellation is a failed read, not a successful empty repository.
        #expect(result == nil)
    }

    @Test func ambientGitRepositorySelectionEnvironmentIsScrubbed() throws {
        let repoA = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repoA) }
        let repoB = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repoB) }
        try Data("x\n".utf8).write(to: repoA.appendingPathComponent("only-in-a.txt"))

        // Poisoned ambient environment pointing every git invocation at repoB.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_DIR"] = repoB.appendingPathComponent(".git").path
        environment["GIT_WORK_TREE"] = repoB.path
        let service = GitDiffService(environment: environment)

        let root = try #require(service.repositoryRoot(for: repoA.path))
        #expect(
            URL(fileURLWithPath: root).resolvingSymlinksInPath().path
                == repoA.resolvingSymlinksInPath().path
        )
        let changed = try #require(service.changedFiles(repoRoot: repoA.path))
        #expect(changed.files.map(\.path) == ["only-in-a.txt"])
    }

    @Test func changedFilesReturnsFailureInsteadOfEmptySuccessWhenGitFails() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let failingGit = repo.appendingPathComponent("failing-git.sh")
        try Data("#!/bin/sh\nexit 2\n".utf8).write(to: failingGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: failingGit.path
        )

        let service = GitDiffService(gitExecutableURL: failingGit)

        #expect(service.changedFiles(repoRoot: repo.path) == nil)
    }

    @Test func trackedGitlinkDirectoryCanProduceAFileDiff() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let nested = repo.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for arguments in [
            ["init", "--quiet"],
            ["config", "user.email", "tests@cmux.dev"],
            ["config", "user.name", "cmux tests"],
            ["commit", "--allow-empty", "--quiet", "-m", "nested init"],
        ] {
            try runTestGit(in: nested, arguments)
        }
        try runTestGit(in: repo, ["add", "--", "Nested"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add gitlink"])
        try Data("changed\n".utf8).write(to: nested.appendingPathComponent("change.txt"))
        try runTestGit(in: nested, ["add", "--", "change.txt"])
        try runTestGit(in: nested, ["commit", "--quiet", "-m", "advance nested"])

        let service = GitDiffService()
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: "Nested"))

        #expect(diff.unifiedDiff.contains("Subproject commit"))
    }

    @Test func stalledGitProcessIsTerminatedAtTheDeadline() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // A fake git that emits nothing and hangs far past the deadline.
        let stalledGit = repo.appendingPathComponent("stalled-git.sh")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: stalledGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stalledGit.path
        )

        let service = GitDiffService(
            gitExecutableURL: stalledGit,
            processDeadlineSeconds: 0.5
        )

        // Assert on causality, not latency: the watchdog must let this
        // synchronous call RETURN. We run it off the test thread and wait on its
        // completion signal. The 5s wait deadline bounds only the failure path
        // and sits an order of magnitude below the fake git's 30s sleep, so a
        // working watchdog (kills the subprocess at ~0.5s) signals long before
        // it, while a broken watchdog never signals and the wait times out,
        // failing the test deterministically. No measured duration is asserted.
        let finished = DispatchSemaphore(value: 0)
        let box = StalledRootBox()
        DispatchQueue.global().async {
            box.value = service.repositoryRoot(for: repo.path)
            finished.signal()
        }
        let signalled = finished.wait(timeout: .now() + 5)
        #expect(signalled == .success)
        #expect(box.value == nil)
    }

    @Test func repositoryRootResultPreservesTimeout() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let stalledGit = repo.appendingPathComponent("stalled-root-git.sh")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: stalledGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stalledGit.path
        )
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
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: failingGit.path
        )
        let service = GitDiffService(gitExecutableURL: failingGit)

        switch service.fileDiffResult(repoRoot: repo.path, path: "a.txt") {
        case .failed:
            break
        default:
            Issue.record("A Git execution failure was flattened into a missing file")
        }
    }

    @Test func deadlineTerminatesDescendantsInTheGitProcessGroup() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let stalledGit = repo.appendingPathComponent("descendant-git.sh")
        try Data(
            "#!/bin/sh\ntrap '' TERM\nsleep 30 &\necho $! > child.pid\nwait\n".utf8
        ).write(to: stalledGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stalledGit.path
        )

        let service = GitDiffService(
            gitExecutableURL: stalledGit,
            processDeadlineSeconds: 5
        )
        #expect(service.repositoryRoot(for: repo.path) == nil)

        let pidText = try String(contentsOf: repo.appendingPathComponent("child.pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try #require(Int32(pidText))
        // A terminated grandchild can remain as a zombie briefly while launchd
        // reaps it. That is no longer executing and therefore satisfies the
        // containment guarantee even though `kill(pid, 0)` still finds it.
        #expect(!isExecutingProcess(childPID))
    }

    private func makeTempRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-diff-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for arguments in [
            ["init", "--quiet"],
            ["config", "user.email", "tests@cmux.dev"],
            ["config", "user.name", "cmux tests"],
            ["commit", "--allow-empty", "--quiet", "-m", "init"],
        ] {
            try runTestGit(in: root, arguments)
        }
        return root
    }

    private func makeUnbornTempRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-diff-unborn-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runTestGit(in: root, ["init", "--quiet"])
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

    private func isExecutingProcess(_ processIdentifier: pid_t) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "state=", "-p", String(processIdentifier)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let state = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return state?.hasPrefix("Z") == false
    }
}

/// Carries the off-thread `repositoryRoot` result back to the test. The write
/// happens before the semaphore is signalled and the read happens after the
/// wait returns `.success`, so that ordering (not a lock) makes the single
/// hand-off memory-safe; hence `@unchecked Sendable`.
private final class StalledRootBox: @unchecked Sendable {
    var value: String?
}
