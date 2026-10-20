import Foundation
import Testing
@testable import CmuxGit

// Each test walks on its own runner: the app's shared runner refuses
// overlapping walks, which would make these tests order-dependent.
@Suite struct GitWorkTreeRootTests {
    private func lookup(_ directory: String, timeout: Duration = .seconds(60)) async -> GitWorkTreeRootLookup {
        await GitMetadataService().workTreeRoot(
            forDirectory: directory,
            timeout: timeout,
            runner: BoundedBlockingRunner(label: "test.work-tree-root.\(UUID().uuidString)")
        )
    }

    @Test func nestedDirectoryResolvesToCheckoutRoot() async throws {
        let fixture = try GitRepositoryFixture()
        let nested = fixture.root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(await lookup(nested.path) == .root(fixture.root.standardizedFileURL.path))
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

        #expect(await lookup(nested.path) == .root(worktree.standardizedFileURL.path))
    }

    @Test func directoryOutsideAnyRepositoryHasNoRoot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-no-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(await lookup(base.path) == .notInRepository)
    }

    /// A timeout is not a finding: Copy Project Root must not treat it as
    /// "outside a repository" and copy the working directory instead.
    @Test func expiredDeadlineIsUnavailableNotOutsideARepository() async throws {
        let fixture = try GitRepositoryFixture()

        #expect(await lookup(fixture.root.path, timeout: .zero) == .unavailable)
    }
}
