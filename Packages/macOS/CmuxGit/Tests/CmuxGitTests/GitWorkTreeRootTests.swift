import Foundation
import Testing
@testable import CmuxGit

@Suite struct GitWorkTreeRootTests {
    @Test func nestedDirectoryResolvesToCheckoutRoot() async throws {
        let fixture = try GitRepositoryFixture()
        let nested = fixture.root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let root = await GitMetadataService().workTreeRoot(forDirectory: nested.path, timeout: .seconds(60))

        #expect(root == fixture.root.standardizedFileURL.path)
    }

    @Test func linkedWorktreeResolvesToItsOwnRoot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-worktree-root-\(UUID().uuidString)", isDirectory: true)
        let worktree = base.appendingPathComponent("feature", isDirectory: true)
        let realGitDir = base.appendingPathComponent("main/.git/worktrees/feature", isDirectory: true)
        let nested = worktree.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realGitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "gitdir: \(realGitDir.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        let root = await GitMetadataService().workTreeRoot(forDirectory: nested.path, timeout: .seconds(60))

        #expect(root == worktree.standardizedFileURL.path)
    }

    @Test func directoryOutsideAnyRepositoryHasNoRoot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-no-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let root = await GitMetadataService().workTreeRoot(forDirectory: base.path, timeout: .seconds(60))

        #expect(root == nil)
    }
}

@Suite struct GitWorkTreeRootDeadlineTests {
    @Test func expiredDeadlineReturnsNilInsteadOfWalking() async throws {
        let fixture = try GitRepositoryFixture()

        let root = await GitMetadataService().workTreeRoot(
            forDirectory: fixture.root.path,
            timeout: .zero
        )

        #expect(root == nil)
    }
}
