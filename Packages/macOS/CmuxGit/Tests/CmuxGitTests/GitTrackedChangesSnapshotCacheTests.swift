import Foundation
import Testing
@testable import CmuxGit

@Suite struct GitTrackedChangesSnapshotCacheTests {
    private func waitUntil(
        maxYields: Int = 5_000,
        _ predicate: () -> Bool
    ) async -> Bool {
        for _ in 0..<maxYields {
            if predicate() {
                return true
            }
            await Task.yield()
        }
        return predicate()
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentWindowFallbacksForNestedDirectoriesRunOneTrackedScan() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("nested/file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let nestedDirectory = fixture.root.appendingPathComponent("nested")
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: nestedDirectory.path)
        )
        let filePath = nestedDirectory.appendingPathComponent("file.txt").path
        let reader = GatedCountingGitFileStatusReader(gatedPath: filePath)
        let cache = GitTrackedChangesSnapshotCache()
        let firstWindow = GitMetadataService(
            fileStatusReader: reader,
            trackedChangesSnapshotCache: cache
        )
        let secondWindow = GitMetadataService(
            fileStatusReader: reader,
            trackedChangesSnapshotCache: cache
        )
        let startGate = ConcurrentOperationStartGate(expectedCount: 2)
        let fallbackTask = Task {
            await withTaskGroup(of: GitTrackedChangesSnapshot.self) { group in
                group.addTask {
                    await startGate.wait()
                    return await firstWindow.gitTrackedChangesSnapshot(
                        repository: repository,
                        trackedPathEventGeneration: GitTrackedPathEventGeneration(
                            namespace: UUID(),
                            generation: 1
                        )
                    )
                }
                group.addTask {
                    await startGate.wait()
                    return await secondWindow.gitTrackedChangesSnapshot(
                        repository: repository,
                        trackedPathEventGeneration: GitTrackedPathEventGeneration(
                            namespace: UUID(),
                            generation: 1
                        )
                    )
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }
        defer {
            reader.openGate()
            fallbackTask.cancel()
        }

        #expect(await waitUntil { reader.callCount(atPath: filePath) >= 1 })
        for _ in 0..<1_000 {
            await Task.yield()
        }
        let scanCountWhileBlocked = reader.callCount(atPath: filePath)
        reader.openGate()
        let snapshots = await fallbackTask.value

        #expect(scanCountWhileBlocked == 1)
        #expect(snapshots.count == 2)
    }

    @Test func laterFallbackRescansAndCatchesMissedWatcherEvent() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let fileURL = fixture.root.appendingPathComponent("file.txt")
        let reader = CountingGitFileStatusReader()
        let service = GitMetadataService(fileStatusReader: reader)
        let fallbackAuthority = GitTrackedPathEventGeneration(namespace: UUID(), generation: 1)

        let clean = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: fallbackAuthority
        )
        try "hello, dirty".write(to: fileURL, atomically: true, encoding: .utf8)
        let dirty = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: fallbackAuthority
        )

        #expect(clean.isDirty == false)
        #expect(dirty.isDirty)
        #expect(reader.callCount(atPath: fileURL.path) == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func canceledWaiterDoesNotLeaveCompletedSnapshotInFlight() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let filePath = fixture.root.appendingPathComponent("file.txt").path
        let reader = GatedCountingGitFileStatusReader(gatedPath: filePath)
        let service = GitMetadataService(fileStatusReader: reader)
        let generation = GitTrackedPathEventGeneration(namespace: UUID(), generation: 1)
        let canceledWaiter = Task {
            await service.gitTrackedChangesSnapshot(
                repository: repository,
                trackedPathEventGeneration: generation
            )
        }
        defer { reader.openGate() }

        #expect(await waitUntil { reader.callCount(atPath: filePath) == 1 })
        canceledWaiter.cancel()
        reader.openGate()
        _ = await canceledWaiter.value
        _ = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: generation
        )

        #expect(reader.callCount(atPath: filePath) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentServicesSharingCacheRunOneTrackedScan() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let filePath = fixture.root.appendingPathComponent("file.txt").path
        let reader = GatedCountingGitFileStatusReader(gatedPath: filePath)
        let cache = GitTrackedChangesSnapshotCache()
        let callerCount = 8
        let startGate = ConcurrentOperationStartGate(expectedCount: callerCount)
        let generation = GitTrackedPathEventGeneration(namespace: UUID(), generation: 7)
        let services = (0..<callerCount).map { _ in
            GitMetadataService(
                fileStatusReader: reader,
                trackedChangesSnapshotCache: cache
            )
        }
        let snapshotsTask = Task {
            await withTaskGroup(of: GitTrackedChangesSnapshot.self) { group in
                for service in services {
                    group.addTask {
                        await startGate.wait()
                        return await service.gitTrackedChangesSnapshot(
                            repository: repository,
                            trackedPathEventGeneration: generation
                        )
                    }
                }
                var snapshots: [GitTrackedChangesSnapshot] = []
                for await snapshot in group {
                    snapshots.append(snapshot)
                }
                return snapshots
            }
        }
        defer {
            reader.openGate()
            snapshotsTask.cancel()
        }

        #expect(reader.waitForCallCount(atPath: filePath, atLeast: 1, timeout: 2))
        _ = reader.waitForCallCount(atPath: filePath, atLeast: 2, timeout: 0.5)
        let trackedScanOperationCount = reader.callCount(atPath: filePath)
        reader.openGate()
        let snapshots = await snapshotsTask.value

        #expect(trackedScanOperationCount == 1)
        #expect(snapshots.count == callerCount)
        let firstSnapshot = try #require(snapshots.first)
        #expect(snapshots.allSatisfy { $0 == firstSnapshot })
    }

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
