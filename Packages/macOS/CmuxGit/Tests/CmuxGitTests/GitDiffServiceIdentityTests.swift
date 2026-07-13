import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitDiffServiceIdentityTests {
    @Test func undecodableGitPathFailsClosed() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let emittingGit = repo.appendingPathComponent("invalid-path-git.sh")
        try Data(
            """
            #!/bin/sh
            case "$3:$5" in
              rev-parse:*) printf 'HEAD\\n' ;;
              diff:--numstat) printf '1\\t0\\tnon-\\377\\0' ;;
              diff:--name-status) printf 'A\\0non-\\377\\0' ;;
              ls-files:*) exit 0 ;;
              *) exit 2 ;;
            esac
            """.utf8
        ).write(to: emittingGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: emittingGit.path
        )

        let service = GitDiffService(gitExecutableURL: emittingGit)

        // Unsupported Git path bytes must not become an authoritative empty
        // repository state, which would render as "No changes" on iOS.
        #expect(service.changedFiles(repoRoot: repo.path) == nil)
    }

    @Test func untrackedReplacementOfRenameSourceDiffsAsAnAddition() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("original\n".utf8).write(to: repo.appendingPathComponent("A.txt"))
        try runTestGit(in: repo, ["add", "--", "A.txt"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add A"])
        try runTestGit(in: repo, ["mv", "--", "A.txt", "B.txt"])
        try Data("replacement\n".utf8).write(to: repo.appendingPathComponent("A.txt"))

        let service = GitDiffService()
        let changed = try #require(service.changedFiles(repoRoot: repo.path))
        let replacement = try #require(changed.files.first { $0.path == "A.txt" })
        let diff = try #require(
            service.fileDiff(
                repoRoot: repo.path,
                path: replacement.path,
                oldPath: replacement.oldPath,
                status: replacement.status,
                additions: replacement.additions,
                deletions: replacement.deletions,
                snapshotToken: replacement.snapshotToken
            )
        )

        #expect(replacement.status == .untracked)
        #expect(diff.unifiedDiff.contains("+replacement"))
        #expect(!diff.unifiedDiff.contains("-original"))
    }

    @Test func corruptHeadDoesNotUseTheEmptyTreeBaseline() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("staged\n".utf8).write(to: repo.appendingPathComponent("staged.txt"))
        try runTestGit(in: repo, ["add", "--", "staged.txt"])
        let head = try String(contentsOf: repo.appendingPathComponent(".git/HEAD"), encoding: .utf8)
        let prefix = "ref: "
        let ref = try #require(head.hasPrefix(prefix) ? head.dropFirst(prefix.count) : nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refURL = repo.appendingPathComponent(".git").appendingPathComponent(ref)
        try Data("bogus\n".utf8).write(to: refURL)

        let service = GitDiffService()

        // Falling back to the empty tree here would present every indexed
        // entry as an addition even though repository state is corrupt.
        #expect(service.changedFiles(repoRoot: repo.path) == nil)
    }

    @Test func symbolicHeadOutsideBranchesDoesNotUseTheEmptyTreeBaseline() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("staged\n".utf8).write(to: repo.appendingPathComponent("staged.txt"))
        try runTestGit(in: repo, ["add", "--", "staged.txt"])
        try Data("ref: refs/tags/missing\n".utf8)
            .write(to: repo.appendingPathComponent(".git/HEAD"))

        let service = GitDiffService()

        // Only a missing branch ref is a valid unborn repository. Treating a
        // missing tag ref as unborn would present the index as new additions.
        #expect(service.changedFiles(repoRoot: repo.path) == nil)
    }

    private func makeTempRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-identity-tests-\(UUID().uuidString)")
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
