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
        let sourceEventID = GitTrackedPathEventID(rawValue: 8_080)
        let firstAuthority = await firstWindow.recordTrackedPathEvent(
            for: identity,
            sourceEventID: sourceEventID
        )
        let secondAuthority = await secondWindow.recordTrackedPathEvent(
            for: identity,
            sourceEventID: sourceEventID
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
        while await cache.inFlightWaiterCountForTesting() < 2 {
            await Task.yield()
        }
        for waiter in canceledWaiters {
            waiter.cancel()
        }
        while await cache.inFlightWaiterCountForTesting() != 0 {
            await Task.yield()
        }
        reader.openGate()
        for waiter in canceledWaiters {
            _ = await waiter.value
        }
        #expect(await cache.inFlightSnapshotCountForTesting() == 0)
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

    @Test(.timeLimit(.minutes(1)))
    func concurrentServicesSharingCacheRunOneTrackedScan() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let filePath = fixture.root.appendingPathComponent("file.txt").path
        let reader = GatedCountingGitFileStatusReader(gatedPath: filePath)
        let scope = GitTrackedChangesSnapshotScope()
        let callerCount = 8
        let startGate = ConcurrentOperationStartGate(expectedCount: callerCount)
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let authority = await scope.authority(for: identity, fallbackRoundID: nil)
        let services = (0..<callerCount).map { _ in
            GitMetadataService(
                fileStatusReader: reader,
                trackedChangesSnapshotScope: scope
            )
        }
        let snapshotsTask = Task {
            await withTaskGroup(of: GitTrackedChangesSnapshot.self) { group in
                for service in services {
                    group.addTask {
                        await startGate.wait()
                        return await service.gitTrackedChangesSnapshot(
                            repository: repository,
                            snapshotRequest: .watcherEvent(authority)
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

        #expect(await waitUntil { reader.callCount(atPath: filePath) >= 1 })
        for _ in 0..<1_000 {
            await Task.yield()
        }
        let trackedScanOperationCount = reader.callCount(atPath: filePath)
        reader.openGate()
        let snapshots = await snapshotsTask.value

        #expect(trackedScanOperationCount == 1)
        #expect(snapshots.count == callerCount)
        let firstSnapshot = try #require(snapshots.first)
        #expect(snapshots.allSatisfy { $0 == firstSnapshot })
    }

    @Test func delayedFallbackRoundReusesItsStampedAuthority() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let filePath = fixture.root.appendingPathComponent("file.txt").path
        let reader = CountingGitFileStatusReader()
        let scope = GitTrackedChangesSnapshotScope()
        let service = GitMetadataService(
            fileStatusReader: reader,
            trackedChangesSnapshotScope: scope
        )
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let namespace = UUID()
        let generation40 = GitFallbackRoundID(namespace: namespace, sequence: 40)
        let generation41 = GitFallbackRoundID(namespace: namespace, sequence: 41)
        let authority40 = await scope.authority(for: identity, fallbackRoundID: generation40)
        let authority41 = await scope.authority(for: identity, fallbackRoundID: generation41)

        _ = await service.gitTrackedChangesSnapshot(
            repository: repository,
            snapshotRequest: .fallbackRound(id: generation40, authority: authority40)
        )
        _ = await service.gitTrackedChangesSnapshot(
            repository: repository,
            snapshotRequest: .fallbackRound(id: generation41, authority: authority41)
        )
        _ = await service.gitTrackedChangesSnapshot(
            repository: repository,
            snapshotRequest: .fallbackRound(id: generation40, authority: authority40)
        )

        #expect(reader.callCount(atPath: filePath) == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func delayedFirstRoundSurvivesSixLaterRoundStamps() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let filePath = fixture.root.appendingPathComponent("file.txt").path
        let reader = GatedCountingGitFileStatusReader(gatedPath: filePath)
        let scope = GitTrackedChangesSnapshotScope(maximumSnapshotCount: 16)
        let service = GitMetadataService(
            fileStatusReader: reader,
            trackedChangesSnapshotScope: scope
        )
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let namespace = UUID()
        let firstRound = GitFallbackRoundID(namespace: namespace, sequence: 1)
        let firstAuthority = await scope.authority(for: identity, fallbackRoundID: firstRound)
        let firstTask = Task {
            await service.gitTrackedChangesSnapshot(
                repository: repository,
                snapshotRequest: .fallbackRound(id: firstRound, authority: firstAuthority)
            )
        }
        defer {
            reader.openGate()
            firstTask.cancel()
        }

        #expect(await waitUntil { reader.callCount(atPath: filePath) == 1 })
        for generation in 2...7 {
            let round = GitFallbackRoundID(
                namespace: namespace,
                sequence: UInt64(generation)
            )
            _ = await scope.authority(for: identity, fallbackRoundID: round)
        }
        reader.openGate()
        _ = await firstTask.value
        _ = await service.gitTrackedChangesSnapshot(
            repository: repository,
            snapshotRequest: .fallbackRound(id: firstRound, authority: firstAuthority)
        )

        #expect(reader.callCount(atPath: filePath) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func watcherRevisionDuringFallbackReturnsSupersededWithoutJoining() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let filePath = fixture.root.appendingPathComponent("file.txt").path
        let reader = GatedCountingGitFileStatusReader(gatedPath: filePath)
        let scope = GitTrackedChangesSnapshotScope()
        let service = GitMetadataService(
            fileStatusReader: reader,
            trackedChangesSnapshotScope: scope
        )
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let round = GitFallbackRoundID(namespace: UUID(), sequence: 1)
        let fallbackAuthority = await scope.authority(for: identity, fallbackRoundID: round)
        let fallbackTask = Task {
            await service.gitTrackedChangesSnapshotRead(
                repository: repository,
                snapshotRequest: .fallbackRound(id: round, authority: fallbackAuthority)
            )
        }
        defer {
            reader.openGate()
            fallbackTask.cancel()
        }

        #expect(await waitUntil { reader.callCount(atPath: filePath) == 1 })
        let watcherAuthority = await scope.recordWatcherEvent(for: identity)
        let watcherTask = Task {
            await service.gitTrackedChangesSnapshotRead(
                repository: repository,
                snapshotRequest: .watcherEvent(watcherAuthority)
            )
        }
        #expect(await waitUntil { reader.callCount(atPath: filePath) == 2 })
        reader.openGate()
        let fallbackRead = try #require(await fallbackTask.value)
        let watcherRead = try #require(await watcherTask.value)

        #expect(!fallbackRead.isCurrent)
        #expect(watcherRead.isCurrent)
        #expect(reader.callCount(atPath: filePath) == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func missingIndexStillReportsSupersededAuthority() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let indexPath = fixture.gitDirectory.appendingPathComponent("index").path
        let reader = GatedCountingGitFileStatusReader(gatedPath: indexPath)
        let scope = GitTrackedChangesSnapshotScope()
        let service = GitMetadataService(
            fileStatusReader: reader,
            trackedChangesSnapshotScope: scope
        )
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let authority = await scope.authority(for: identity, fallbackRoundID: nil)
        let readTask = Task {
            await service.gitTrackedChangesSnapshotRead(
                repository: repository,
                snapshotRequest: .watcherEvent(authority)
            )
        }
        defer {
            reader.openGate()
            readTask.cancel()
        }

        #expect(await waitUntil { reader.callCount(atPath: indexPath) == 1 })
        _ = await scope.recordWatcherEvent(for: identity)
        reader.openGate()
        let read = try #require(await readTask.value)

        #expect(!read.isCurrent)
    }

    @Test func repositoryAuthorityStateIsBounded() async throws {
        let fixtures = try (0..<3).map { _ -> GitRepositoryFixture in
            let fixture = try GitRepositoryFixture()
            try fixture.writeBranch("main")
            return fixture
        }
        let scope = GitTrackedChangesSnapshotScope(maximumRepositoryCount: 2)

        for fixture in fixtures {
            let repository = try #require(
                GitMetadataService.resolveGitRepository(containing: fixture.root.path)
            )
            let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
            _ = await scope.authority(for: identity, fallbackRoundID: nil)
        }

        #expect(await scope.repositoryStateCountForTesting() == 2)
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
        let identity = GitTrackedChangesRepositoryIdentity(repository: repository)
        let authority1 = GitTrackedChangesSnapshotAuthority(
            repositoryIdentity: identity,
            repositoryEpoch: namespace,
            repositoryRevision: 1,
            fallbackRoundID: nil
        )
        let authority2 = GitTrackedChangesSnapshotAuthority(
            repositoryIdentity: identity,
            repositoryEpoch: namespace,
            repositoryRevision: 2,
            fallbackRoundID: nil
        )
        let authority3 = GitTrackedChangesSnapshotAuthority(
            repositoryIdentity: identity,
            repositoryEpoch: namespace,
            repositoryRevision: 3,
            fallbackRoundID: nil
        )

        await cache.store(
            firstSnapshot,
            repository: repository,
            indexStatSignature: indexStatSignature,
            authority: authority1
        )
        await cache.store(
            secondSnapshot,
            repository: repository,
            indexStatSignature: indexStatSignature,
            authority: authority2
        )
        await cache.store(
            refreshedFirstSnapshot,
            repository: repository,
            indexStatSignature: indexStatSignature,
            authority: authority1
        )
        await cache.store(
            thirdSnapshot,
            repository: repository,
            indexStatSignature: indexStatSignature,
            authority: authority3
        )

        let refreshedFirst = await cache.snapshot(
            repository: repository,
            indexStatSignature: indexStatSignature,
            authority: authority1
        )
        let evictedSecond = await cache.snapshot(
            repository: repository,
            indexStatSignature: indexStatSignature,
            authority: authority2
        )
        let third = await cache.snapshot(
            repository: repository,
            indexStatSignature: indexStatSignature,
            authority: authority3
        )

        #expect(refreshedFirst == refreshedFirstSnapshot)
        #expect(evictedSecond == nil)
        #expect(third == thirdSnapshot)
    }
}
