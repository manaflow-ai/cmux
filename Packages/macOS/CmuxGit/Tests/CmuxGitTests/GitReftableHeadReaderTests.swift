import Foundation
import Testing
@testable import CmuxGit

/// The cost side of reftable support: the `git` fallback must stay off the
/// files backend entirely, and must not run again while the reftable stack is
/// unchanged.
@Suite struct GitReftableHeadReaderTests {
    @Test func filesBackendRepositoryNeverConsultsGit() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let reader = CountingGitReftableHeadReader()
        let service = GitMetadataService(
            fileStatusReader: SystemGitFileStatusReader(),
            reftableHeadReader: reader
        )

        let metadata = await service.workspaceMetadata(for: fixture.root.path)
        let checkedOut = await service.checkedOutBranch(forDirectory: fixture.root.path)

        #expect(metadata.branch == "main")
        #expect(checkedOut == .branch("main"))
        #expect(reader.callCount == 0)
    }

    @Test func unreadableHeadOnFilesBackendNeverConsultsGit() async throws {
        let fixture = try GitRepositoryFixture()
        let reader = CountingGitReftableHeadReader()
        let service = GitMetadataService(
            fileStatusReader: SystemGitFileStatusReader(),
            reftableHeadReader: reader
        )

        let checkedOut = await service.checkedOutBranch(forDirectory: fixture.root.path)

        #expect(checkedOut == .unreadable)
        #expect(reader.callCount == 0)
    }

    @Test(.enabled(if: ReftableRepositoryFixture.isSupported, "requires git with --ref-format=reftable"))
    func reftableStackSignatureChangesOnlyWhenRefsChange() async throws {
        let fixture = try ReftableRepositoryFixture(branch: "main")
        let reader = CountingGitReftableHeadReader(
            base: MemoizedGitReftableHeadReader(base: SystemGitReftableHeadReader())
        )
        let service = GitMetadataService(
            fileStatusReader: SystemGitFileStatusReader(),
            reftableHeadReader: reader
        )

        for _ in 0..<3 {
            #expect(await service.workspaceMetadata(for: fixture.root.path).branch == "main")
        }
        let signaturesBeforeCommit = reader.distinctStackSignatureCount
        try fixture.commitEmpty(message: "second")
        #expect(await service.workspaceMetadata(for: fixture.root.path).branch == "main")

        #expect(signaturesBeforeCommit == 1)
        #expect(reader.distinctStackSignatureCount == 2)
    }

    @Test func memoReusesResolutionUntilTheStackSignatureChanges() {
        let base = CountingGitReftableHeadReader(base: StubGitReftableHeadReader())
        let memo = MemoizedGitReftableHeadReader(base: base)

        _ = memo.head(workTreeRoot: "/repo", stackSignature: "a")
        _ = memo.head(workTreeRoot: "/repo", stackSignature: "a")
        #expect(base.callCount == 1)

        _ = memo.head(workTreeRoot: "/repo", stackSignature: "b")
        #expect(base.callCount == 2)

        _ = memo.head(workTreeRoot: "/other", stackSignature: "a")
        #expect(base.callCount == 3)
    }

    @Test func memoRemembersAnUnresolvedRead() {
        let base = CountingGitReftableHeadReader()
        let memo = MemoizedGitReftableHeadReader(base: base)

        #expect(memo.head(workTreeRoot: "/repo", stackSignature: "a") == nil)
        #expect(memo.head(workTreeRoot: "/repo", stackSignature: "a") == nil)

        #expect(base.callCount == 1)
    }

    @Test func memoEvictsTheOldestCheckoutBeyondItsBound() {
        let base = CountingGitReftableHeadReader(base: StubGitReftableHeadReader())
        let memo = MemoizedGitReftableHeadReader(base: base, maximumEntryCount: 2)

        _ = memo.head(workTreeRoot: "/first", stackSignature: "a")
        _ = memo.head(workTreeRoot: "/second", stackSignature: "a")
        _ = memo.head(workTreeRoot: "/third", stackSignature: "a")
        #expect(base.callCount == 3)

        // The two most recent stay cached, the first is gone.
        _ = memo.head(workTreeRoot: "/second", stackSignature: "a")
        _ = memo.head(workTreeRoot: "/third", stackSignature: "a")
        #expect(base.callCount == 3)

        _ = memo.head(workTreeRoot: "/first", stackSignature: "a")
        #expect(base.callCount == 4)
    }
}

/// Resolves every checkout to the same fixed `HEAD`.
private struct StubGitReftableHeadReader: GitReftableHeadReading {
    func head(workTreeRoot: String, stackSignature: String) -> GitReftableHead? {
        GitReftableHead(
            symbolicFullName: "refs/heads/main",
            objectID: String(repeating: "a", count: 40)
        )
    }
}
