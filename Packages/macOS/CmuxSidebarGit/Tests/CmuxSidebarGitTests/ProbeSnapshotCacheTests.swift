import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

private actor SequencedGatedMetadataReader: WorkspaceGitMetadataReading {
    private let metadataByProbe: [GitWorkspaceMetadata]
    private var startedProbeCount = 0
    private var releasedProbeIndexes: Set<Int> = []
    private var gateWaitersByProbeIndex: [Int: CheckedContinuation<Void, Never>] = [:]

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

    func waitForProbeCount(_ minimumCount: Int, maxYields: Int = 5_000) async -> Bool {
        for _ in 0..<maxYields {
            if startedProbeCount >= minimumCount {
                return true
            }
            await Task.yield()
        }
        return startedProbeCount >= minimumCount
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

    @Test func consecutiveFallbackRoundsUseDistinctSnapshotAuthority() throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "feature/x")),
            clock: ManualGitPollClock()
        )

        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)

        let firstRound = try #require(
            service.trackedPathEventGenerationForSnapshot(
                directory: directory,
                reason: "fallbackTimer"
            )
        )
        let secondRound = try #require(
            service.trackedPathEventGenerationForSnapshot(
                directory: directory,
                reason: "fallbackTimer"
            )
        )

        #expect(firstRound != secondRound)
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
        #expect(await reader.waitForProbeCount(1))

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
        for _ in 0..<3 {
            if await reader.waitForProbeCount(2, maxYields: 100) {
                break
            }
            await clock.waitForSleeper()
            await clock.resumeNext()
        }
        #expect(await reader.waitForProbeCount(2))

        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)

        await reader.releaseProbe(at: 1)
        service.clearWorkspaceGitProbes(workspaceId: workspaceId)
    }
}
