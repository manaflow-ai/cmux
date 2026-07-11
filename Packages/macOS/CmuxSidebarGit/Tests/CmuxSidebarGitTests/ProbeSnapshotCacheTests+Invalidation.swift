import Foundation
import Testing
@testable import CmuxGit
@testable import CmuxSidebarGit

extension ProbeSnapshotCacheTests {
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
