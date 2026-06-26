import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

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

    @Test(.timeLimit(.minutes(1)))
    func fallbackRefreshBypassesTrackedSnapshotCacheGeneration() async throws {
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
        await reader.waitForTrackedPathEventGenerationProbe()

        let generations = await reader.probedTrackedPathEventGenerations
        #expect(generations == [nil])
        let advancedGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))
        #expect(advancedGeneration != initialGeneration)
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
        await reader.waitForTrackedPathEventGenerationProbe()

        let generations = await reader.probedTrackedPathEventGenerations
        #expect(generations == [nil])
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
        await reader.waitForTrackedPathEventGenerationProbe(count: 1)

        service.recordWorkspaceGitMetadataFilesystemEvent(for: secondKey)
        let secondGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))
        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: secondPanelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        for _ in 0..<50 {
            if service.workspaceGitProbeRerunPending(for: firstKey),
               service.workspaceGitProbeRerunPending(for: secondKey) {
                break
            }
            await Task.yield()
        }

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
}
