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
        await workspaceMetadata(for: directory, snapshotRequest: nil)
    }

    func workspaceMetadata(
        for directory: String,
        snapshotRequest: GitTrackedChangesSnapshotRequest?
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

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() {
                return true
            }
            try? await clock.sleep(for: .milliseconds(1))
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

        let generations = await reader.probedFallbackRoundIDs
        let firstRound = try #require(generations.first)
        let secondRound = try #require(generations.last)
        #expect(generations.count == 2)
        #expect(firstRound != secondRound)
    }

    @Test(.timeLimit(.minutes(1)))
    func twoSidebarWindowsShareOneFallbackScanForNestedDirectories() async throws {
        let fixture = try SidebarGitRepositoryFixture()
        let firstDirectory = fixture.root.path
        let secondDirectory = fixture.nestedDirectory.path
        let firstTrackedPath = fixture.trackedFile.path
        let fileStatusReader = GatedCountingSidebarGitFileStatusReader(gatedPath: firstTrackedPath)
        let sharedScope = GitTrackedChangesSnapshotScope()
        let sharedGitMetadataService = GitMetadataService(
            fileStatusReader: fileStatusReader,
            trackedChangesSnapshotScope: sharedScope
        )
        let firstHost = RecordingSidebarGitHost()
        let secondHost = RecordingSidebarGitHost()
        let (firstWorkspaceId, firstPanelId) = firstHost.addWorkspace(panelDirectory: firstDirectory)
        let (secondWorkspaceId, secondPanelId) = secondHost.addWorkspace(panelDirectory: secondDirectory)
        let firstKey = WorkspaceGitProbeKey(workspaceId: firstWorkspaceId, panelId: firstPanelId)
        let secondKey = WorkspaceGitProbeKey(workspaceId: secondWorkspaceId, panelId: secondPanelId)
        let firstClock = ManualGitPollClock()
        let secondClock = ManualGitPollClock()
        let fallbackClock = ManualGitPollClock()
        let fallbackCoordinator = WorkspaceGitFallbackCoordinator(
            clock: fallbackClock
        )
        let sharedLimiter = WorkspaceGitMetadataProbeLimiter(limit: 1)
        let firstService = SidebarGitMetadataService(
            workspaceGitMetadataReader: sharedGitMetadataService,
            gitMetadataService: sharedGitMetadataService,
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: sharedLimiter,
            clock: firstClock,
            fallbackCoordinator: fallbackCoordinator
        )
        let secondService = SidebarGitMetadataService(
            workspaceGitMetadataReader: sharedGitMetadataService,
            gitMetadataService: sharedGitMetadataService,
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: sharedLimiter,
            clock: secondClock,
            fallbackCoordinator: fallbackCoordinator
        )
        firstService.attach(host: firstHost)
        secondService.attach(host: secondHost)
        firstService.workspaceGitTrackedDirectoryByKey[firstKey] = firstDirectory
        secondService.workspaceGitTrackedDirectoryByKey[secondKey] = secondDirectory
        firstService.markWorkspaceGitSnapshotCacheEligible(directory: firstDirectory)
        secondService.markWorkspaceGitSnapshotCacheEligible(directory: secondDirectory)
        firstService.updateWorkspaceGitMetadataFallbackTimer()
        secondService.updateWorkspaceGitMetadataFallbackTimer()
        var firstEvents = firstHost.projectionEvents().makeAsyncIterator()
        var secondEvents = secondHost.projectionEvents().makeAsyncIterator()
        defer {
            fileStatusReader.openGate()
            firstService.clearWorkspaceGitProbes(workspaceId: firstWorkspaceId)
            secondService.clearWorkspaceGitProbes(workspaceId: secondWorkspaceId)
        }

        await fallbackClock.waitForSleeper(duration: 5 * 60)
        #expect(await fallbackClock.recordedDurations == [5 * 60])
        await fallbackClock.resumeNext(duration: 5 * 60)
        await firstClock.waitForSleeper(duration: 0)
        await secondClock.waitForSleeper(duration: 0)
        await firstClock.resumeNext(duration: 0)
        await secondClock.resumeNext(duration: 0)
        await fileStatusReader.waitForCallCount(atPath: firstTrackedPath, atLeast: 1)
        fileStatusReader.openGate()
        while let event = await firstEvents.next() {
            if case .gitBranch = event { break }
        }
        while let event = await secondEvents.next() {
            if case .gitBranch = event { break }
        }

        #expect(fileStatusReader.callCount(atPath: firstTrackedPath) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func fallbackCoordinatorDoesNotRetainReleasedWindow() async {
        let fallbackClock = ManualGitPollClock()
        let coordinator = WorkspaceGitFallbackCoordinator(clock: fallbackClock)
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        var service: SidebarGitMetadataService? = SidebarGitMetadataService(
            workspaceGitMetadataReader: GatedMetadataReader(
                metadata: .repository(branch: "feature/x")
            ),
            gitMetadataService: GitMetadataService(),
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 1),
            clock: ManualGitPollClock(),
            fallbackCoordinator: coordinator
        )
        weak let weakService = service
        service?.attach(host: host)
        service?.workspaceGitTrackedDirectoryByKey[key] = "/tmp/repo"
        service?.updateWorkspaceGitMetadataFallbackTimer()

        #expect(coordinator.registeredServiceCountForTesting == 1)
        #expect(coordinator.hasScheduledTimerForTesting)
        await fallbackClock.waitForSleeper(duration: 5 * 60)

        service = nil
        #expect(weakService == nil)
        #expect(await waitUntil {
            coordinator.registeredServiceCountForTesting == 0
                && !coordinator.hasScheduledTimerForTesting
        })
        #expect(coordinator.registeredServiceCountForTesting == 0)
        #expect(!coordinator.hasScheduledTimerForTesting)
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

        service.refreshTrackedWorkspaceGitMetadata(reason: "fallbackTimer")
        await clock.waitForSleeper(duration: 0)
        await clock.resumeNext(duration: 0)
        #expect(await reader.waitForTrackedPathEventGenerationProbe())

        let generations = await reader.probedFallbackRoundIDs
        let generation = try #require(generations.first)
        #expect(generations.count == 1)
        #expect(generation.sequence > 0)
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

        let requests = await reader.probedSnapshotRequests
        let request = try #require(requests.first ?? nil)
        #expect(requests.count == 1)
        guard case .watcherEvent = request else {
            Issue.record("Expected watcher-event snapshot request")
            return
        }
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

        let requests = await reader.probedSnapshotRequests
        #expect(secondGeneration != firstGeneration)
        let request = try #require(requests.first ?? nil)
        #expect(requests.count == 1)
        guard case .watcherEvent = request else {
            Issue.record("Expected watcher-event snapshot request")
            return
        }
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

        service.refreshTrackedWorkspaceGitMetadata(reason: "fallbackTimer")
        await clock.waitForSleeper(duration: 0)
        await clock.resumeNext(duration: 0)
        await reader.waitForProbeCount(1)

        service.recordWorkspaceGitMetadataFilesystemEvent(for: key)
        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        #expect(service.workspaceGitProbeRerunPending(for: key))

        await reader.releaseProbe(at: 0)
        #expect(await waitUntil {
            service.workspaceGitSnapshotTasksByDirectory[directory] == nil
        })
        await clock.waitForSleeper(duration: 0)

        // The stale completion has drained, but the replacement task remains
        // parked on its zero-delay clock. Suppression cannot depend on the new
        // scan beginning.
        #expect(await reader.probeCount == 1)
        #expect(await clock.pendingSleeperCount > 0)
        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)

        await clock.resumeNext(duration: 0)
        await reader.waitForProbeCount(2)

        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)

        await reader.releaseProbe(at: 1)
        service.clearWorkspaceGitProbes(workspaceId: workspaceId)
    }
}
