import Foundation
import Testing
@testable import CmuxGit

@Suite struct GitTrackedChangesSnapshotCacheTests {
    @Test func alternatingGenerationsKeepSeparateTrackedSnapshotCacheEntries() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let filePath = fixture.root.appendingPathComponent("file.txt").path
        let reader = CountingGitFileStatusReader()
        let service = GitMetadataService(fileStatusReader: reader)
        let namespace = UUID()
        let generation40 = GitTrackedPathEventGeneration(namespace: namespace, generation: 40)
        let generation41 = GitTrackedPathEventGeneration(namespace: namespace, generation: 41)

        _ = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: generation40
        )
        _ = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: generation41
        )
        _ = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: generation40
        )

        #expect(reader.callCount(atPath: filePath) == 2)
    }

    @Test func refreshedCacheEntryMovesBehindOlderEntryForEviction() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let cache = GitTrackedChangesSnapshotCache(maximumEntryCount: 2)
        let indexStatSignature = GitIndexStatSignature(
            size: 1,
            mtimeSeconds: 2,
            mtimeNanoseconds: 3
        )
        let firstSnapshot = GitTrackedChangesSnapshot(
            isDirty: false,
            indexSignature: "first",
            indexContentSignature: "first-content"
        )
        let refreshedFirstSnapshot = GitTrackedChangesSnapshot(
            isDirty: true,
            indexSignature: "first-refreshed",
            indexContentSignature: "first-refreshed-content"
        )
        let secondSnapshot = GitTrackedChangesSnapshot(
            isDirty: false,
            indexSignature: "second",
            indexContentSignature: "second-content"
        )
        let thirdSnapshot = GitTrackedChangesSnapshot(
            isDirty: false,
            indexSignature: "third",
            indexContentSignature: "third-content"
        )
        let namespace = UUID()
        let generation1 = GitTrackedPathEventGeneration(namespace: namespace, generation: 1)
        let generation2 = GitTrackedPathEventGeneration(namespace: namespace, generation: 2)
        let generation3 = GitTrackedPathEventGeneration(namespace: namespace, generation: 3)

        await cache.store(
            firstSnapshot,
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: generation1
        )
        await cache.store(
            secondSnapshot,
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: generation2
        )
        await cache.store(
            refreshedFirstSnapshot,
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: generation1
        )
        await cache.store(
            thirdSnapshot,
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: generation3
        )

        let refreshedFirst = await cache.snapshot(
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: generation1
        )
        let evictedSecond = await cache.snapshot(
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: generation2
        )
        let third = await cache.snapshot(
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: generation3
        )

        #expect(refreshedFirst == refreshedFirstSnapshot)
        #expect(evictedSecond == nil)
        #expect(third == thirdSnapshot)
    }
}
