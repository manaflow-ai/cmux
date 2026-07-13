import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitDiffServiceSnapshotBoundsTests {
    @Test func fileDiffRejectsContentChangedSinceStatusSnapshot() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = "Snapshot.swift"
        let fileURL = repo.appendingPathComponent(path)
        try Data("let value = 0\n".utf8).write(to: fileURL)
        try runTestGit(in: repo, ["add", "--", path])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add snapshot fixture"])
        try Data("let value = 1\n".utf8).write(to: fileURL)

        let service = GitDiffService()
        let changed = try #require(service.changedFiles(repoRoot: repo.path))
        let visible = try #require(changed.files.first { $0.path == path })

        // Preserve the same path, status, line counts, and byte length while
        // changing the content after the status snapshot.
        try Data("let value = 2\n".utf8).write(to: fileURL)

        let result = service.fileDiffResult(
            repoRoot: repo.path,
            path: visible.path,
            oldPath: visible.oldPath,
            status: visible.status,
            additions: visible.additions,
            deletions: visible.deletions,
            snapshotToken: visible.snapshotToken
        )
        guard case .notFound = result else {
            Issue.record("Expected stale snapshot rejection, got \(result)")
            return
        }
    }

    @Test func cappedStatusDropsUnverifiedUntrackedReplacement() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        for index in 0..<120 {
            let path = "deleted-with-long-name-\(1000 + index).txt"
            try Data("original\n".utf8).write(to: repo.appendingPathComponent(path))
        }
        let replacementPath = "zzzz-replacement.txt"
        try Data("original\n".utf8).write(to: repo.appendingPathComponent(replacementPath))
        try runTestGit(in: repo, ["add", "--", "."])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add capped fixtures"])
        try runTestGit(in: repo, ["rm", "--quiet", "-r", "--", "."])
        try Data("replacement\n".utf8).write(to: repo.appendingPathComponent(replacementPath))

        let service = GitDiffService()
        let changed = try #require(service.changedFiles(repoRoot: repo.path, maxOutputBytes: 512))

        #expect(changed.truncated)
        #expect(!changed.files.contains { file in
            file.path == replacementPath && file.status == .untracked
        })
    }

    @Test func rowLimitBoundsReturnedSnapshotTokens() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        for index in 0..<20 {
            try Data("new\n".utf8).write(
                to: repo.appendingPathComponent("untracked-\(index).txt")
            )
        }

        let changed = try #require(
            GitDiffService().changedFiles(repoRoot: repo.path, maxFiles: 3)
        )

        #expect(changed.files.count == 3)
        #expect(changed.files.allSatisfy { !$0.snapshotToken.isEmpty })
        #expect(changed.truncated)
    }

    @Test func configuredDiffOrderCannotExposeCappedReplacementAsUntracked() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let replacementPath = "aaaa-replacement.txt"
        try Data("original\n".utf8).write(to: repo.appendingPathComponent(replacementPath))
        for index in 0..<120 {
            let path = "zzzz-deleted-with-long-name-\(1000 + index).txt"
            try Data("original\n".utf8).write(to: repo.appendingPathComponent(path))
        }
        try runTestGit(in: repo, ["add", "--", "."])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add reordered fixtures"])
        try runTestGit(in: repo, ["rm", "--quiet", "-r", "--", "."])
        try Data("replacement\n".utf8).write(to: repo.appendingPathComponent(replacementPath))
        let orderFile = repo.appendingPathComponent(".git/test-diff-order")
        try Data("zzzz*\naaaa*\n".utf8).write(to: orderFile)
        try runTestGit(in: repo, ["config", "diff.orderFile", orderFile.path])

        let changed = try #require(
            GitDiffService().changedFiles(repoRoot: repo.path, maxOutputBytes: 512)
        )

        #expect(changed.truncated)
        #expect(!changed.files.contains { file in
            file.path == replacementPath && file.status == .untracked
        })
    }

    private func makeTempRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-snapshot-bounds-tests-\(UUID().uuidString)")
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
