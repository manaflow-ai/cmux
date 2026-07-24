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
        await cache.store(authorization(repoRoot: "/expired"))

        await cache.store(authorization(repoRoot: "/fresh"))

        #expect(await cache.entryCount() == 1)
        #expect(await cache.snapshot(forRepoRoot: "/expired") == nil)
    }

    @Test func authorizedPathCacheEnforcesLRUEntryBound() async {
        let cache = WorkspaceChangesAuthorizedPathCache(maximumEntryCount: 2)
        await cache.store(authorization(repoRoot: "/a"))
        await cache.store(authorization(repoRoot: "/b"))
        _ = await cache.snapshot(forRepoRoot: "/a")

        await cache.store(authorization(repoRoot: "/c"))

        #expect(await cache.entryCount() == 2)
        #expect(await cache.snapshot(forRepoRoot: "/a") != nil)
        #expect(await cache.snapshot(forRepoRoot: "/b") == nil)
        #expect(await cache.snapshot(forRepoRoot: "/c") != nil)
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
        repoRoot: String
    ) -> WorkspaceChangesAuthorizedPathCache.Snapshot {
        WorkspaceChangesAuthorizedPathCache.Snapshot(
            repoRoot: repoRoot,
            currentPaths: ["file.txt"],
            basePaths: ["file.txt"]
        )
    }
}
