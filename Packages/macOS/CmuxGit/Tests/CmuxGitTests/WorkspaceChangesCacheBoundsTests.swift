import Foundation
import Testing
@testable import CmuxGit

@Suite struct WorkspaceChangesCacheBoundsTests {
    @Test func summaryStorePurgesAllExpiredEntries() async {
        let clock = TestWorkspaceChangesClock()
        let cache = WorkspaceChangesSummaryCache(
            ttl: .seconds(15),
            maximumEntryCount: 64,
            clock: clock
        )
        await cache.store(summary(repoRoot: "/expired"), forRepoRoot: "/expired")
        await clock.advance(by: .seconds(16))

        await cache.store(summary(repoRoot: "/fresh"), forRepoRoot: "/fresh")

        #expect(await cache.entryCount() == 1)
        #expect(await cache.summary(forRepoRoot: "/expired") == nil)
        #expect(await cache.summary(forRepoRoot: "/fresh") != nil)
    }

    @Test func summaryCacheEnforcesLRUEntryBound() async {
        let cache = WorkspaceChangesSummaryCache(maximumEntryCount: 2)
        await cache.store(summary(repoRoot: "/a"), forRepoRoot: "/a")
        await cache.store(summary(repoRoot: "/b"), forRepoRoot: "/b")
        _ = await cache.summary(forRepoRoot: "/a")

        await cache.store(summary(repoRoot: "/c"), forRepoRoot: "/c")

        #expect(await cache.entryCount() == 2)
        #expect(await cache.summary(forRepoRoot: "/a") != nil)
        #expect(await cache.summary(forRepoRoot: "/b") == nil)
        #expect(await cache.summary(forRepoRoot: "/c") != nil)
    }

    @Test func authorizedPathStorePurgesAllExpiredEntries() async {
        let cache = WorkspaceChangesAuthorizedPathCache(
            timeToLive: 0,
            maximumEntryCount: 64
        )
        let expired = authorization(directory: "/expired", repoRoot: "/expired")
        await cache.store(
            expired.authorizedFile,
            for: expired.key,
            awaitsInitialFetch: false
        )

        let fresh = authorization(directory: "/fresh", repoRoot: "/fresh")
        await cache.store(
            fresh.authorizedFile,
            for: fresh.key,
            awaitsInitialFetch: false
        )

        #expect(await cache.entryCount() == 1)
        #expect(await cache.authorizedFileForFetch(key: expired.key, offset: 1) == nil)
    }

    @Test func authorizedPathCacheEnforcesLRUEntryBound() async {
        let cache = WorkspaceChangesAuthorizedPathCache(maximumEntryCount: 2)
        let a = authorization(directory: "/a", repoRoot: "/a")
        let b = authorization(directory: "/b", repoRoot: "/b")
        let c = authorization(directory: "/c", repoRoot: "/c")
        await cache.store(a.authorizedFile, for: a.key, awaitsInitialFetch: false)
        await cache.store(b.authorizedFile, for: b.key, awaitsInitialFetch: false)
        _ = await cache.authorizedFileForFetch(key: a.key, offset: 1)

        await cache.store(c.authorizedFile, for: c.key, awaitsInitialFetch: false)

        #expect(await cache.entryCount() == 2)
        #expect(await cache.authorizedFileForFetch(key: a.key, offset: 1) != nil)
        #expect(await cache.authorizedFileForFetch(key: b.key, offset: 1) == nil)
        #expect(await cache.authorizedFileForFetch(key: c.key, offset: 1) != nil)
    }

    @Test func authorizationSnapshotDoesNotMatchAMovedBaseRevision() async throws {
        let cache = WorkspaceChangesAuthorizedPathCache()
        let old = authorization(
            directory: "/repo",
            repoRoot: "/repo",
            baseCommitOID: "old-oid"
        )
        await cache.store(old.authorizedFile, for: old.key, awaitsInitialFetch: false)

        let oldSnapshot = try #require(await cache.snapshot(
            forRepoRoot: "/repo",
            baseCommitOID: "old-oid"
        ))

        #expect(oldSnapshot.identity == old.authorizedFile.snapshot.identity)
        #expect(await cache.snapshot(
            forRepoRoot: "/repo",
            baseCommitOID: "new-oid"
        ) == nil)
    }

    private func summary(repoRoot: String) -> WorkspaceChangesSummary {
        WorkspaceChangesSummary(
            isRepository: true,
            repoRoot: repoRoot,
            branch: "feature",
            baseRef: "main",
            filesChanged: 1,
            additions: 2,
            deletions: 3
        )
    }

    private func authorization(
        directory: String,
        repoRoot: String,
        baseCommitOID: String = "base-oid"
    ) -> (
        key: WorkspaceChangesAuthorizedPathCache.Key,
        authorizedFile: WorkspaceChangesAuthorizedPathCache.AuthorizedFile
    ) {
        let key = WorkspaceChangesAuthorizedPathCache.Key(
            directory: directory,
            path: "file.txt",
            revision: .current
        )
        let scope = WorkspaceChangesScope(
            repoRoot: repoRoot,
            branch: "feature",
            baseRef: "main",
            diffBase: baseCommitOID,
            diffBaseCommitOID: baseCommitOID
        )
        let snapshot = WorkspaceChangesAuthorizedPathCache.Snapshot(
            identity: UUID(),
            scope: scope,
            currentPaths: ["file.txt"],
            basePaths: ["file.txt"]
        )
        let authorizedFile = WorkspaceChangesAuthorizedPathCache.AuthorizedFile(
            snapshot: snapshot,
            relativePath: "file.txt",
            baseBlobSize: nil,
            baseBlobOID: nil
        )
        return (key, authorizedFile)
    }
}
