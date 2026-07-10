import Foundation
import Testing
@testable import CmuxGit
@testable import CmuxSidebarGit

private final class GatedCountingSidebarGitFileStatusReader: GitFileStatusReading, @unchecked Sendable {
    private let condition = NSCondition()
    private let systemReader = SystemGitFileStatusReader()
    private let gatedPath: String
    private var callsByPath: [String: Int] = [:]
    private var isGateOpen = false
    private var countWaiters: [(path: String, minimumCount: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(gatedPath: String) {
        self.gatedPath = gatedPath
    }

    func status(atPath path: String) -> GitFileStatus? {
        condition.lock()
        callsByPath[path, default: 0] += 1
        let readyWaiters = countWaiters.filter {
            $0.path == path && callsByPath[path, default: 0] >= $0.minimumCount
        }
        countWaiters.removeAll { waiter in
            readyWaiters.contains { $0.path == waiter.path && $0.minimumCount == waiter.minimumCount }
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        while path == gatedPath, !isGateOpen {
            condition.wait()
        }
        condition.unlock()
        return systemReader.status(atPath: path)
    }

    func waitForCallCount(atPath path: String, atLeast minimumCount: Int) async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if callsByPath[path, default: 0] >= minimumCount {
                condition.unlock()
                continuation.resume()
            } else {
                countWaiters.append((path, minimumCount, continuation))
                condition.unlock()
            }
        }
    }

    func callCount(atPath path: String) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return callsByPath[path] ?? 0
    }

    func openGate() {
        condition.lock()
        isGateOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor TwoWindowMetadataBarrier: WorkspaceGitMetadataReading {
    private let service: GitMetadataService
    private var arrivalCount = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(service: GitMetadataService) {
        self.service = service
    }

    func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata {
        await workspaceMetadata(for: directory, trackedPathEventGeneration: nil)
    }

    func workspaceMetadata(
        for directory: String,
        trackedPathEventGeneration: GitTrackedPathEventGeneration?
    ) async -> GitWorkspaceMetadata {
        arrivalCount += 1
        while !arrivalWaiters.isEmpty {
            arrivalWaiters.removeFirst().resume()
        }
        if arrivalCount < 2 {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        } else {
            while !releaseWaiters.isEmpty {
                releaseWaiters.removeFirst().resume()
            }
        }
        return await service.workspaceMetadata(
            for: directory,
            trackedPathEventGeneration: trackedPathEventGeneration
        )
    }

    func waitForBothWindows() async {
        while arrivalCount < 2 {
            await withCheckedContinuation { continuation in
                arrivalWaiters.append(continuation)
            }
        }
    }
}

private actor SequencedGatedMetadataReader: WorkspaceGitMetadataReading {
    private let metadataByProbe: [GitWorkspaceMetadata]
    private var startedProbeCount = 0
    private var releasedProbeIndexes: Set<Int> = []
    private var gateWaitersByProbeIndex: [Int: CheckedContinuation<Void, Never>] = [:]
    private var probeCountWaiters: [(minimumCount: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(metadataByProbe: [GitWorkspaceMetadata]) {
        self.metadataByProbe = metadataByProbe
    }

    func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata {
        await workspaceMetadata(for: directory, trackedPathEventGeneration: nil)
    }

    func workspaceMetadata(
        for directory: String,
        trackedPathEventGeneration: GitTrackedPathEventGeneration?
    ) async -> GitWorkspaceMetadata {
        let probeIndex = startedProbeCount
        startedProbeCount += 1
        let readyCountWaiters = probeCountWaiters.filter { startedProbeCount >= $0.minimumCount }
        probeCountWaiters.removeAll { startedProbeCount >= $0.minimumCount }
        for waiter in readyCountWaiters {
            waiter.continuation.resume()
        }
        if !releasedProbeIndexes.contains(probeIndex) {
            await withCheckedContinuation { continuation in
                if releasedProbeIndexes.contains(probeIndex) {
                    continuation.resume()
                } else {
                    gateWaitersByProbeIndex[probeIndex] = continuation
                }
            }
        }
        return metadataByProbe[min(probeIndex, metadataByProbe.count - 1)]
    }

    func releaseProbe(at index: Int) {
        releasedProbeIndexes.insert(index)
        gateWaitersByProbeIndex.removeValue(forKey: index)?.resume()
    }

    func waitForProbeCount(_ minimumCount: Int) async {
        while startedProbeCount < minimumCount {
            await withCheckedContinuation { continuation in
                probeCountWaiters.append((minimumCount, continuation))
            }
        }
    }

    var probeCount: Int {
        startedProbeCount
    }
}

@MainActor
@Suite struct ProbeSnapshotCacheTests {
    private func makeService(
        host: RecordingSidebarGitHost,
        reader: GatedMetadataReader,
        clock: ManualGitPollClock
    ) -> SidebarGitMetadataService {
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: reader,
            gitMetadataService: GitMetadataService(),
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 2),
            clock: clock
        )
        service.attach(host: host)
        return service
    }

    private func waitUntil(maxYields: Int = 5_000, _ predicate: () -> Bool) async -> Bool {
        for _ in 0..<maxYields {
            if predicate() {
                return true
            }
            await Task.yield()
        }
        return predicate()
    }

    @Test(.timeLimit(.minutes(1)))
    func consecutiveFallbackTicksUseDistinctSnapshotAuthority() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let reader = GatedMetadataReader(metadata: .repository(branch: "feature/x"))
        let clock = ManualGitPollClock()
        let service = makeService(
            host: host,
            reader: reader,
            clock: clock
        )
        service.workspaceGitTrackedDirectoryByKey[key] = directory
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)
        var events = host.projectionEvents().makeAsyncIterator()

        service.refreshTrackedWorkspaceGitMetadata(reason: "fallbackTimer")
        await clock.waitForSleeper(duration: 0)
        await clock.resumeNext(duration: 0)
        while let event = await events.next() {
            if case .gitBranch = event { break }
        }
        service.refreshTrackedWorkspaceGitMetadata(reason: "fallbackTimer")
        await clock.waitForSleeper(duration: 0)
        await clock.resumeNext(duration: 0)
        while let event = await events.next() {
            if case .gitBranch = event { break }
        }

        let generations = await reader.probedTrackedPathEventGenerations.compactMap { $0 }
        let firstRound = try #require(generations.first)
        let secondRound = try #require(generations.last)
        #expect(generations.count == 2)
        #expect(firstRound != secondRound)
    }

    @Test(.timeLimit(.minutes(1)))
    func twoSidebarWindowsShareOneFallbackScanForNestedDirectories() async throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let firstDirectory = testFileURL.deletingLastPathComponent().path
        let secondDirectory = testFileURL.deletingLastPathComponent().deletingLastPathComponent().path
        let fileStatusReader = GatedCountingSidebarGitFileStatusReader(gatedPath: testFileURL.path)
        let sharedCache = GitTrackedChangesSnapshotCache()
        let sharedGitMetadataService = GitMetadataService(
            fileStatusReader: fileStatusReader,
            trackedChangesSnapshotCache: sharedCache
        )
        let readerBarrier = TwoWindowMetadataBarrier(service: sharedGitMetadataService)
        let firstHost = RecordingSidebarGitHost()
        let secondHost = RecordingSidebarGitHost()
        let (firstWorkspaceId, firstPanelId) = firstHost.addWorkspace(panelDirectory: firstDirectory)
        let (secondWorkspaceId, secondPanelId) = secondHost.addWorkspace(panelDirectory: secondDirectory)
        let firstKey = WorkspaceGitProbeKey(workspaceId: firstWorkspaceId, panelId: firstPanelId)
        let secondKey = WorkspaceGitProbeKey(workspaceId: secondWorkspaceId, panelId: secondPanelId)
        let firstClock = ManualGitPollClock()
        let secondClock = ManualGitPollClock()
        let firstService = SidebarGitMetadataService(
            workspaceGitMetadataReader: readerBarrier,
            gitMetadataService: sharedGitMetadataService,
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 2),
            clock: firstClock
        )
        let secondService = SidebarGitMetadataService(
            workspaceGitMetadataReader: readerBarrier,
            gitMetadataService: sharedGitMetadataService,
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 2),
            clock: secondClock
        )
        firstService.attach(host: firstHost)
        secondService.attach(host: secondHost)
        firstService.workspaceGitTrackedDirectoryByKey[firstKey] = firstDirectory
        secondService.workspaceGitTrackedDirectoryByKey[secondKey] = secondDirectory
        firstService.markWorkspaceGitSnapshotCacheEligible(directory: firstDirectory)
        secondService.markWorkspaceGitSnapshotCacheEligible(directory: secondDirectory)
        defer {
            fileStatusReader.openGate()
            firstService.clearWorkspaceGitProbes(workspaceId: firstWorkspaceId)
            secondService.clearWorkspaceGitProbes(workspaceId: secondWorkspaceId)
        }

        firstService.refreshTrackedWorkspaceGitMetadata(reason: "fallbackTimer")
        secondService.refreshTrackedWorkspaceGitMetadata(reason: "fallbackTimer")
        await firstClock.waitForSleeper(duration: 0)
        await secondClock.waitForSleeper(duration: 0)
        await firstClock.resumeNext(duration: 0)
        await secondClock.resumeNext(duration: 0)
        await readerBarrier.waitForBothWindows()
        await fileStatusReader.waitForCallCount(atPath: testFileURL.path, atLeast: 1)
        for _ in 0..<1_000 {
            await Task.yield()
        }

        #expect(fileStatusReader.callCount(atPath: testFileURL.path) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func fallbackRefreshStartsNewSnapshotCacheRound() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "feature/x"))
        let service = makeService(host: host, reader: reader, clock: clock)

        service.workspaceGitTrackedDirectoryByKey[key] = directory
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)
        let initialGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "fallbackTimer"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe())

        let generations = await reader.probedTrackedPathEventGenerations
        let generation = try #require(generations.first ?? nil)
        #expect(generations.count == 1)
        #expect(generation != GitTrackedPathEventGeneration(
            namespace: service.workspaceGitSnapshotCacheNamespace,
            generation: initialGeneration
        ))
        #expect(service.workspaceGitSnapshotCacheGeneration(directory: directory) == initialGeneration)
    }

    @Test(.timeLimit(.minutes(1)))
    func branchChangeBypassesTrackedSnapshotCacheGeneration() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "feature/x"))
        let service = makeService(host: host, reader: reader, clock: clock)

        service.workspaceGitTrackedDirectoryByKey[key] = directory
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "branchChange"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe())

        let generations = await reader.probedTrackedPathEventGenerations
        #expect(generations == [nil])
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["directoryChange", "branchCleared", "unexpectedReason"]
    )
    func nonWatcherRefreshReasonsBypassTrackedSnapshotCacheGeneration(reason: String) async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "feature/x"))
        let service = makeService(host: host, reader: reader, clock: clock)

        service.workspaceGitTrackedDirectoryByKey[key] = directory
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe())

        let generations = await reader.probedTrackedPathEventGenerations
        #expect(generations == [nil])
    }

    @Test(.timeLimit(.minutes(1)))
    func filesystemEventGenerationIsPassedToMetadataReader() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "feature/x"))
        let service = makeService(host: host, reader: reader, clock: clock)

        service.workspaceGitTrackedDirectoryByKey[key] = directory
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)
        let initialGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))
        service.recordWorkspaceGitMetadataFilesystemEvent(for: key)
        let eventGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))
        #expect(eventGeneration != initialGeneration)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe())

        let generations = await reader.probedTrackedPathEventGenerations
        let generation = try #require(generations.first ?? nil)
        #expect(generations.count == 1)
        #expect(generation.namespace == service.workspaceGitSnapshotCacheNamespace)
        #expect(generation.generation == eventGeneration)
    }

    @Test func reusedWatcherMovesCacheGenerationToNewDirectory() throws {
        let oldDirectory = "/tmp/repo"
        let newDirectory = "/tmp/repo/nested"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: oldDirectory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "feature/x")),
            clock: ManualGitPollClock()
        )

        service.setWorkspaceGitMetadataWatcherSourceDirectory(oldDirectory, for: key)
        service.markWorkspaceGitSnapshotCacheEligible(directory: oldDirectory)
        let oldGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: oldDirectory))

        service.moveWorkspaceGitSnapshotCacheEligibility(for: key, to: newDirectory)
        let newGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: newDirectory))

        #expect(service.workspaceGitSnapshotCacheGeneration(directory: oldDirectory) == nil)
        #expect(newGeneration != oldGeneration)
        service.recordWorkspaceGitMetadataFilesystemEvent(for: key)
        #expect(service.workspaceGitSnapshotCacheGeneration(directory: newDirectory) != newGeneration)
    }

    @Test func sharedWatcherDirectoryKeepsCacheEligibilityUntilLastWatcherStops() throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, firstPanelId) = host.addWorkspace(panelDirectory: directory)
        let secondPanelId = UUID()
        let firstKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: firstPanelId)
        let secondKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: secondPanelId)
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "feature/x")),
            clock: ManualGitPollClock()
        )

        service.setWorkspaceGitMetadataWatcherSourceDirectory(directory, for: firstKey)
        service.setWorkspaceGitMetadataWatcherSourceDirectory(directory, for: secondKey)
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)
        let generation = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))

        service.stopWorkspaceGitMetadataWatcher(for: firstKey)
        #expect(service.workspaceGitSnapshotCacheGeneration(directory: directory) == generation)
        service.stopWorkspaceGitMetadataWatcher(for: secondKey)
        #expect(service.workspaceGitSnapshotCacheGeneration(directory: directory) == nil)
    }

    @Test func sharedWatchedPathsEventBumpsDirectoryGenerationOnce() throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, firstPanelId) = host.addWorkspace(panelDirectory: directory)
        let secondPanelId = UUID()
        let firstKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: firstPanelId)
        let secondKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: secondPanelId)
        let watchedPathsKey = WorkspaceGitMetadataWatchedPathsKey(paths: ["/tmp/repo/.git/index"])
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "feature/x")),
            clock: ManualGitPollClock()
        )

        service.setWorkspaceGitMetadataWatcherSourceDirectory(directory, for: firstKey)
        service.setWorkspaceGitMetadataWatcherSourceDirectory(directory, for: secondKey)
        service.setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: firstKey)
        service.setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: secondKey)
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)
        let initialGeneration = service.workspaceGitMetadataFilesystemEventGeneration

        let refreshedKeys = service.recordWorkspaceGitMetadataFilesystemEvent(
            forWatchedPathsKey: watchedPathsKey
        )

        #expect(Set(refreshedKeys) == Set([firstKey, secondKey]))
        #expect(service.workspaceGitMetadataFilesystemEventGeneration == initialGeneration + 1)
    }

    @Test func sharedWatchedPathsEventAssignsSameGenerationToEveryDirectory() throws {
        let firstDirectory = "/tmp/repo/frontend"
        let secondDirectory = "/tmp/repo/backend"
        let host = RecordingSidebarGitHost()
        let (workspaceId, firstPanelId) = host.addWorkspace(panelDirectory: firstDirectory)
        let secondPanelId = UUID()
        let firstKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: firstPanelId)
        let secondKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: secondPanelId)
        let watchedPathsKey = WorkspaceGitMetadataWatchedPathsKey(paths: ["/tmp/repo/.git/index"])
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "feature/x")),
            clock: ManualGitPollClock()
        )

        service.setWorkspaceGitMetadataWatcherSourceDirectory(firstDirectory, for: firstKey)
        service.setWorkspaceGitMetadataWatcherSourceDirectory(secondDirectory, for: secondKey)
        service.setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: firstKey)
        service.setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: secondKey)
        service.markWorkspaceGitSnapshotCacheEligible(directory: firstDirectory)
        service.markWorkspaceGitSnapshotCacheEligible(directory: secondDirectory)
        let initialGeneration = service.workspaceGitMetadataFilesystemEventGeneration

        let refreshedKeys = service.recordWorkspaceGitMetadataFilesystemEvent(
            forWatchedPathsKey: watchedPathsKey
        )
        let firstGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: firstDirectory))
        let secondGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: secondDirectory))

        #expect(Set(refreshedKeys) == Set([firstKey, secondKey]))
        #expect(service.workspaceGitMetadataFilesystemEventGeneration == initialGeneration + 1)
        #expect(firstGeneration == secondGeneration)
    }

    @Test(.timeLimit(.minutes(1)))
    func joinedSnapshotWithNewGenerationQueuesFreshFollowUpProbe() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, firstPanelId) = host.addWorkspace(panelDirectory: directory)
        let secondPanelId = UUID()
        host.workspaces[0].state.panels[secondPanelId] = RecordingSidebarGitHost.PanelState(
            directory: directory
        )
        let firstKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: firstPanelId)
        let secondKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: secondPanelId)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(
            metadata: .repository(branch: "feature/x"),
            gated: true
        )
        let service = makeService(host: host, reader: reader, clock: clock)

        service.workspaceGitTrackedDirectoryByKey[firstKey] = directory
        service.workspaceGitTrackedDirectoryByKey[secondKey] = directory
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)
        let firstGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: firstPanelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe(count: 1))

        service.recordWorkspaceGitMetadataFilesystemEvent(for: secondKey)
        let secondGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))
        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: secondPanelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await waitUntil {
            service.workspaceGitProbeRerunPending(for: firstKey)
                && service.workspaceGitProbeRerunPending(for: secondKey)
        })

        let generations = await reader.probedTrackedPathEventGenerations
        #expect(secondGeneration != firstGeneration)
        let generation = try #require(generations.first ?? nil)
        #expect(generations.count == 1)
        #expect(generation.namespace == service.workspaceGitSnapshotCacheNamespace)
        #expect(generation.generation == firstGeneration)
        #expect(service.workspaceGitProbeRerunPending(for: firstKey))
        #expect(service.workspaceGitProbeRerunPending(for: secondKey))
        await reader.openGate()
        service.clearWorkspaceGitProbes(workspaceId: workspaceId)
    }

    @Test(.timeLimit(.minutes(1)))
    func watcherEventDuringFallbackProbeDoesNotApplyStaleSnapshot() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let clock = ManualGitPollClock()
        let reader = SequencedGatedMetadataReader(metadataByProbe: [
            .repository(branch: "feature/x", isDirty: false),
            .repository(branch: "feature/x", isDirty: true),
        ])
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: reader,
            gitMetadataService: GitMetadataService(),
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 2),
            clock: clock
        )
        service.attach(host: host)
        service.workspaceGitTrackedDirectoryByKey[key] = directory
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "fallbackTimer"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        await reader.waitForProbeCount(1)

        service.recordWorkspaceGitMetadataFilesystemEvent(for: key)
        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await waitUntil { service.workspaceGitProbeRerunPending(for: key) })

        await reader.releaseProbe(at: 0)
        while await reader.probeCount < 2 {
            if await clock.pendingSleeperCount > 0 {
                await clock.resumeNext(duration: 0)
            } else {
                await Task.yield()
            }
        }
        await reader.waitForProbeCount(2)

        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)

        await reader.releaseProbe(at: 1)
        service.clearWorkspaceGitProbes(workspaceId: workspaceId)
    }
}
