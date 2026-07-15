import Foundation
import Testing
@testable import CmuxGit

private final class BlockingSnapshotLoadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didStart = false
    private var isOpen = false

    var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didStart
    }

    func waitUntilReleased() {
        condition.lock()
        didStart = true
        condition.broadcast()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

@Suite struct GitTrackedChangesSnapshotCacheTests {
    func waitUntil(
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
        let scope = GitTrackedChangesSnapshotScope()
        let firstWindow = GitMetadataService(
            fileStatusReader: reader,
            trackedChangesSnapshotScope: scope
        )
        let secondWindow = GitMetadataService(
            fileStatusReader: reader,
            trackedChangesSnapshotScope: scope
        )
        let startGate = ConcurrentOperationStartGate(expectedCount: 2)
        let round = GitFallbackRoundID(namespace: UUID(), sequence: 1)
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let authority = await scope.authority(for: identity, fallbackRoundID: round)
        let fallbackTask = Task {
            await withTaskGroup(of: GitTrackedChangesSnapshot.self) { group in
                group.addTask {
                    await startGate.wait()
                    return await firstWindow.gitTrackedChangesSnapshot(
                        repository: repository,
                        snapshotRequest: .fallbackRound(id: round, authority: authority)
                    )
                }
                group.addTask {
                    await startGate.wait()
                    return await secondWindow.gitTrackedChangesSnapshot(
                        repository: repository,
                        snapshotRequest: .fallbackRound(id: round, authority: authority)
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

    @Test(.timeLimit(.minutes(1)))
    func duplicateWindowWatcherDeliveryRunsOneTrackedScan() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let filePath = fixture.root.appendingPathComponent("file.txt").path
        let reader = GatedCountingGitFileStatusReader(gatedPath: filePath)
        let scope = GitTrackedChangesSnapshotScope()
        let firstWindow = GitMetadataService(
            fileStatusReader: reader,
            trackedChangesSnapshotScope: scope
        )
        let secondWindow = GitMetadataService(
            fileStatusReader: reader,
            trackedChangesSnapshotScope: scope
        )
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let sourceEventID = GitTrackedPathEventID(rawValue: UInt64.max - 2)
        let firstAuthority = await firstWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(sourceEventID)
        )
        let secondAuthority = await secondWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(sourceEventID)
        )
        let startGate = ConcurrentOperationStartGate(expectedCount: 2)
        let snapshotsTask = Task {
            await withTaskGroup(of: GitTrackedChangesSnapshot.self) { group in
                group.addTask {
                    await startGate.wait()
                    return await firstWindow.gitTrackedChangesSnapshot(
                        repository: repository,
                        snapshotRequest: .watcherEvent(firstAuthority)
                    )
                }
                group.addTask {
                    await startGate.wait()
                    return await secondWindow.gitTrackedChangesSnapshot(
                        repository: repository,
                        snapshotRequest: .watcherEvent(secondAuthority)
                    )
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }
        defer {
            reader.openGate()
            snapshotsTask.cancel()
        }

        #expect(firstAuthority == secondAuthority)
        #expect(await waitUntil { reader.callCount(atPath: filePath) == 1 })
        reader.openGate()
        #expect(await snapshotsTask.value.count == 2)
        #expect(reader.callCount(atPath: filePath) == 1)

        let newerAuthority = await firstWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(GitTrackedPathEventID(rawValue: UInt64.max - 1))
        )
        #expect(newerAuthority != firstAuthority)
        _ = await firstWindow.gitTrackedChangesSnapshot(
            repository: repository,
            snapshotRequest: .watcherEvent(newerAuthority)
        )
        #expect(reader.callCount(atPath: filePath) == 2)

        let olderAuthority = await secondWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(GitTrackedPathEventID(rawValue: UInt64.max - 3))
        )
        #expect(olderAuthority == newerAuthority)
        _ = await secondWindow.gitTrackedChangesSnapshot(
            repository: repository,
            snapshotRequest: .watcherEvent(olderAuthority)
        )
        #expect(reader.callCount(atPath: filePath) == 2)

        let unknownAuthority = await firstWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .unknown
        )
        #expect(unknownAuthority != olderAuthority)
        _ = await firstWindow.gitTrackedChangesSnapshot(
            repository: repository,
            snapshotRequest: .watcherEvent(unknownAuthority)
        )
        #expect(reader.callCount(atPath: filePath) == 3)

        let secondUnknownAuthority = await secondWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .unknown
        )
        #expect(secondUnknownAuthority != unknownAuthority)
        _ = await secondWindow.gitTrackedChangesSnapshot(
            repository: repository,
            snapshotRequest: .watcherEvent(secondUnknownAuthority)
        )
        #expect(reader.callCount(atPath: filePath) == 4)

        let resetAuthority = await firstWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .sequenceReset
        )
        let postResetAuthority = await firstWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(GitTrackedPathEventID(rawValue: 1))
        )
        let duplicatePostResetAuthority = await secondWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(GitTrackedPathEventID(rawValue: 1))
        )
        #expect(resetAuthority != secondUnknownAuthority)
        #expect(postResetAuthority != resetAuthority)
        #expect(duplicatePostResetAuthority == postResetAuthority)
    }

    @Test func delayedPreResetWatermarkCannotBlockWrappedSequence() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let scope = GitTrackedChangesSnapshotScope()
        let firstWindow = GitMetadataService(trackedChangesSnapshotScope: scope)
        let secondWindow = GitMetadataService(trackedChangesSnapshotScope: scope)

        let preReset = await firstWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(GitTrackedPathEventID(rawValue: UInt64.max - 3))
        )
        let reset = await firstWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .sequenceReset
        )
        let delayedNewerPreReset = await secondWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(GitTrackedPathEventID(rawValue: UInt64.max - 2))
        )
        let delayedOlderPreReset = await secondWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(GitTrackedPathEventID(rawValue: UInt64.max - 4))
        )
        let wrapped = await firstWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(GitTrackedPathEventID(rawValue: 1))
        )
        let repeatedReset = await secondWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .sequenceReset
        )
        let duplicateWrapped = await secondWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(GitTrackedPathEventID(rawValue: 1))
        )
        let delayedPreResetAfterWrap = await secondWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(GitTrackedPathEventID(rawValue: UInt64.max - 1))
        )
        let nextWrapped = await firstWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(GitTrackedPathEventID(rawValue: 2))
        )
        let duplicateNextWrapped = await secondWindow.recordTrackedPathEvent(
            for: identity,
            sourceEvent: .stable(GitTrackedPathEventID(rawValue: 2))
        )

        #expect(reset != preReset)
        #expect(delayedNewerPreReset != reset)
        #expect(delayedOlderPreReset == delayedNewerPreReset)
        #expect(wrapped != delayedNewerPreReset)
        #expect(repeatedReset != wrapped)
        #expect(duplicateWrapped == repeatedReset)
        #expect(delayedPreResetAfterWrap == repeatedReset)
        #expect(nextWrapped != repeatedReset)
        #expect(duplicateNextWrapped == nextWrapped)
    }

    @Test func laterFallbackRescansAndCatchesMissedWatcherEvent() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let fileURL = fixture.root.appendingPathComponent("file.txt")
        let reader = CountingGitFileStatusReader()
        let scope = GitTrackedChangesSnapshotScope()
        let service = GitMetadataService(
            fileStatusReader: reader,
            trackedChangesSnapshotScope: scope
        )
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let fallbackNamespace = UUID()
        let firstRound = GitFallbackRoundID(namespace: fallbackNamespace, sequence: 1)
        let firstAuthority = await scope.authority(for: identity, fallbackRoundID: firstRound)

        let clean = await service.gitTrackedChangesSnapshot(
            repository: repository,
            snapshotRequest: .fallbackRound(id: firstRound, authority: firstAuthority)
        )
        try "hello, dirty".write(to: fileURL, atomically: true, encoding: .utf8)
        let secondRound = GitFallbackRoundID(namespace: fallbackNamespace, sequence: 2)
        let secondAuthority = await scope.authority(for: identity, fallbackRoundID: secondRound)
        let dirty = await service.gitTrackedChangesSnapshot(
            repository: repository,
            snapshotRequest: .fallbackRound(id: secondRound, authority: secondAuthority)
        )

        #expect(clean.isDirty == false)
        #expect(dirty.isDirty)
        #expect(reader.callCount(atPath: fileURL.path) == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func allCanceledWaitersCleanUpAfterSharedLoadCompletes() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let filePath = fixture.root.appendingPathComponent("file.txt").path
        let reader = GatedCountingGitFileStatusReader(gatedPath: filePath)
        let cache = GitTrackedChangesSnapshotCache()
        let scope = GitTrackedChangesSnapshotScope(snapshotCache: cache)
        let service = GitMetadataService(
            fileStatusReader: reader,
            trackedChangesSnapshotScope: scope
        )
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let authority = await scope.authority(for: identity, fallbackRoundID: nil)
        let startGate = ConcurrentOperationStartGate(expectedCount: 2)
        let canceledWaiters = (0..<2).map { _ in
            Task {
                await startGate.wait()
                return await service.gitTrackedChangesSnapshot(
                    repository: repository,
                    snapshotRequest: .watcherEvent(authority)
                )
            }
        }
        defer { reader.openGate() }

        #expect(await waitUntil { reader.callCount(atPath: filePath) == 1 })
        for waiter in canceledWaiters {
            waiter.cancel()
        }
        for waiter in canceledWaiters {
            _ = await waiter.value
        }
        reader.openGate()
        _ = await service.gitTrackedChangesSnapshot(
            repository: repository,
            snapshotRequest: .watcherEvent(authority)
        )

        #expect(reader.callCount(atPath: filePath) == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationBeforeLoadReleaseNeverStoresLateCompletion() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let cache = GitTrackedChangesSnapshotCache(maximumEntryCount: 256)
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let epoch = UUID()
        let indexStatSignature = GitIndexStatSignature(
            size: 1,
            mtimeSeconds: 2,
            mtimeNanoseconds: 3
        )
        let snapshot = GitTrackedChangesSnapshot(
            isDirty: true,
            indexSignature: "late",
            indexContentSignature: "late-content"
        )

        var cancellationViolations = 0
        for revision in 1...20 {
            let authority = GitTrackedChangesSnapshotAuthority(
                repositoryIdentity: identity,
                repositoryEpoch: epoch,
                repositoryRevision: UInt64(revision),
                fallbackRoundID: nil
            )
            let loadGate = BlockingSnapshotLoadGate()
            let readTask = Task(priority: .high) {
                await cache.snapshot(
                    repository: repository,
                    indexStatSignature: indexStatSignature,
                    authority: authority
                ) {
                    loadGate.waitUntilReleased()
                    return snapshot
                }
            }
            #expect(await waitUntil { loadGate.hasStarted })

            await Task.detached(priority: .background) {
                readTask.cancel()
            }.value
            loadGate.open()
            let canceledResult = await readTask.value
            let cachedResult = await cache.snapshot(
                repository: repository,
                indexStatSignature: indexStatSignature,
                authority: authority
            )
            if canceledResult != nil || cachedResult != nil {
                cancellationViolations += 1
            }
        }
        #expect(cancellationViolations == 0)
    }

}
