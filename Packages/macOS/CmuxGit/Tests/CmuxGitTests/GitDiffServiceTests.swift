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

        #expect(diff.unifiedDiff.contains("+changed"))
        #expect(!diff.unifiedDiff.contains("EXTERNAL"))
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
        let unbounded = service.changedFiles(repoRoot: repo.path)
        #expect(unbounded.files.count == 500)
        #expect(!unbounded.truncated)

        let bounded = service.changedFiles(repoRoot: repo.path, maxOutputBytes: 2048)
        #expect(bounded.truncated)
        #expect(!bounded.files.isEmpty)
        #expect(bounded.files.count < 500)
        // The byte cap must only ever drop whole records: every surviving
        // path is complete, never a prefix cut mid-filename.
        #expect(bounded.files.allSatisfy { $0.path.hasSuffix(".txt") })
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

        // Without the cancellation bail this repo reports its untracked file.
        #expect(result.files.isEmpty)
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
        let changed = service.changedFiles(repoRoot: repoA.path)
        #expect(changed.files.map(\.path) == ["only-in-a.txt"])
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
        let start = Date()
        let root = service.repositoryRoot(for: repo.path)
        let elapsed = Date().timeIntervalSince(start)

        // The watchdog must kill the subprocess at ~0.5s; without it this call
        // blocks for the full 30s sleep (and the phone's RPC timeout would
        // leave the process running).
        #expect(root == nil)
        #expect(elapsed < 5)
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
}
