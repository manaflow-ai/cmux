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

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }
}
