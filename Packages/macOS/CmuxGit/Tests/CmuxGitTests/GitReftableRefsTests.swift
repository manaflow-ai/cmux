import Foundation
import Testing
@testable import CmuxGit

/// Ref reads against git's reftable ref backend.
///
/// A reftable repository keeps a permanent placeholder `HEAD`
/// (`ref: refs/heads/.invalid`) and stores the real refs, including the `HEAD`
/// symref, in a binary reftable stack. Parsing `HEAD` alone therefore reports
/// `.invalid` as the branch and never changes when the checkout does
/// (https://github.com/manaflow-ai/cmux/issues/10170).
///
/// Skipped, not failed, when the available git cannot create such a repository.
@Suite(.enabled(if: ReftableRepositoryFixture.isSupported, "requires git with --ref-format=reftable"))
struct GitReftableRefsTests {
    @Test func reportsBranchFromReftableStackInsteadOfPlaceholder() async throws {
        let fixture = try ReftableRepositoryFixture(branch: "theo.leruitte/support-dog/preprod")

        let metadata = await GitMetadataService().workspaceMetadata(for: fixture.root.path)

        #expect(metadata.isRepository)
        #expect(metadata.branch == "theo.leruitte/support-dog/preprod")
    }

    @Test func classifiesReftableCheckoutAsItsRealBranch() async throws {
        let fixture = try ReftableRepositoryFixture(branch: "feature/reftable")

        let checkedOut = await GitMetadataService().checkedOutBranch(forDirectory: fixture.root.path)

        #expect(checkedOut == .branch("feature/reftable"))
    }

    @Test func classifiesDetachedReftableHeadAsDetached() async throws {
        let fixture = try ReftableRepositoryFixture(branch: "main")
        try fixture.detachHead()

        let checkedOut = await GitMetadataService().checkedOutBranch(forDirectory: fixture.root.path)

        #expect(checkedOut == .detached)
    }

    @Test func headSignatureChangesWhenReftableCheckoutChanges() async throws {
        let fixture = try ReftableRepositoryFixture(branch: "main")
        let service = GitMetadataService()

        let before = try #require(await service.workspaceMetadata(for: fixture.root.path).headSignature)
        try fixture.checkoutNewBranch("feature/switched")
        let afterBranchSwitch = try #require(
            await service.workspaceMetadata(for: fixture.root.path).headSignature
        )
        try fixture.commitEmpty(message: "second")
        let afterCommit = try #require(
            await service.workspaceMetadata(for: fixture.root.path).headSignature
        )

        #expect(before != afterBranchSwitch)
        #expect(afterBranchSwitch != afterCommit)
    }

    @Test func reportsHeadCommitFromReftableStack() async throws {
        let fixture = try ReftableRepositoryFixture(branch: "main")
        let expected = try fixture.headCommit()
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )

        let commit = GitMetadataService().resolvedCurrentCommit(repository: repository)

        #expect(commit == expected)
    }

    @Test func watchesTheReftableStackDirectory() async throws {
        let fixture = try ReftableRepositoryFixture(branch: "main")

        let paths = try #require(await GitMetadataService().watchedPaths(for: fixture.root.path))

        #expect(paths.contains { $0.hasSuffix("/.git/reftable") })
    }

    @Test func reportsBranchForLinkedReftableWorktree() async throws {
        let fixture = try ReftableRepositoryFixture(branch: "main")
        let worktreeRoot = try fixture.addWorktree(name: "linked", branch: "feature/linked")

        let metadata = await GitMetadataService().workspaceMetadata(for: worktreeRoot.path)

        #expect(metadata.branch == "feature/linked")
    }
}
