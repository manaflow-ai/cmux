import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct ProbeSchedulingTests {
    private func makeService(
        host: RecordingSidebarGitHost,
        reader: GatedMetadataReader,
        clock: ManualGitPollClock,
        pullRequestProbing: RecordingPullRequestProbing = RecordingPullRequestProbing()
    ) -> SidebarGitMetadataService {
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: reader,
            gitMetadataService: GitMetadataService(),
            pullRequestProbing: pullRequestProbing,
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 2),
            clock: clock
        )
        service.attach(host: host)
        return service
    }

    /// The initial probe's retry offsets [0, 0.5, 1.5, 3, 6, 10] are absolute
    /// offsets from scheduling time, walked as sequential clock gaps. The
    /// reader gate stays closed so no snapshot applies mid-walk (an applied
    /// non-repo snapshot would legitimately finish the probe and cancel the
    /// remaining retries).
    @Test func initialProbeWalksRetryOffsetsAsSequentialGaps() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/probe-test")
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .nonRepository, gated: true)
        let service = makeService(host: host, reader: reader, clock: clock)

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )

        var durations: [TimeInterval] = []
        for _ in 0..<6 {
            await clock.waitForSleeper()
            durations = await clock.recordedDurations
            await clock.resumeNext()
        }
        #expect(durations == [0, 0.5, 1.0, 1.5, 3.0, 4.0])
        await reader.openGate()
    }

    /// A remote workspace never schedules the initial probe.
    @Test func remoteWorkspaceSkipsInitialProbe() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/remote")
        host.workspaces[0].state.isRemote = true
        let clock = ManualGitPollClock()
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .nonRepository),
            clock: clock
        )

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )

        #expect(await clock.recordedDurations.isEmpty)
        #expect(service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty)
    }

    /// A repository probe projects the branch (with dirty flag) onto the
    /// panel and, with PR polling enabled, schedules a PR refresh.
    @Test func repositorySnapshotProjectsBranchAndSchedulesPullRequestRefresh() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "feature/x", isDirty: true))
        let pullRequestProbing = RecordingPullRequestProbing()
        let service = makeService(
            host: host,
            reader: reader,
            clock: clock,
            pullRequestProbing: pullRequestProbing
        )

        let events = host.projectionEvents()
        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()

        var sawBranch = false
        for await event in events {
            if case .gitBranch(workspaceId, panelId, "feature/x", true) = event {
                sawBranch = true
                break
            }
        }
        #expect(sawBranch)
        #expect(host.workspaces[0].state.panels[panelId]?.branch == SidebarPanelGitBranch(branch: "feature/x", isDirty: true))
        #expect(pullRequestProbing.scheduledRefreshes.contains {
            $0.workspaceId == workspaceId && $0.panelId == panelId && $0.reason == "localGitProbe"
        })
    }

    /// Reapplying the same branch from a filesystem-triggered git probe keeps
    /// the sidebar branch fresh without forcing another PR refresh when that
    /// panel is already tracked by the PR poller.
    @Test func knownBranchSnapshotDoesNotForceDuplicatePullRequestRefresh() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "feature/x",
            isDirty: false
        )
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "feature/x", isDirty: true))
        let pullRequestProbing = RecordingPullRequestProbing()
        pullRequestProbing.trackedPanelIdsByWorkspace[workspaceId] = [panelId]
        let service = makeService(
            host: host,
            reader: reader,
            clock: clock,
            pullRequestProbing: pullRequestProbing
        )

        let events = host.projectionEvents()
        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()

        for await event in events {
            if case .gitBranch = event { break }
        }
        #expect(host.workspaces[0].state.panels[panelId]?.branch == SidebarPanelGitBranch(
            branch: "feature/x",
            isDirty: true
        ))
        #expect(pullRequestProbing.scheduledRefreshes.isEmpty)
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
        await reader.waitForTrackedPathEventGenerationProbe()

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

    /// Restored sessions can already have a branch projected before the first
    /// local git probe runs. If the PR poller has no tracking state yet, that
    /// same-branch snapshot must still seed one refresh.
    @Test func restoredKnownBranchSnapshotSeedsPullRequestRefreshWhenUntracked() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "feature/x",
            isDirty: false
        )
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "feature/x", isDirty: false))
        let pullRequestProbing = RecordingPullRequestProbing()
        let service = makeService(
            host: host,
            reader: reader,
            clock: clock,
            pullRequestProbing: pullRequestProbing
        )

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "restore"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        while await reader.probedDirectories.isEmpty {
            await Task.yield()
        }
        for _ in 0..<50 {
            if pullRequestProbing.scheduledRefreshes.count == 1 { break }
            await Task.yield()
        }

        #expect(pullRequestProbing.scheduledRefreshes.count == 1)
        let scheduledRefresh = try #require(pullRequestProbing.scheduledRefreshes.first)
        #expect(scheduledRefresh.workspaceId == workspaceId)
        #expect(scheduledRefresh.panelId == panelId)
        #expect(scheduledRefresh.reason == "localGitProbe")
    }

    /// A filesystem event that arrives while a probe is already in flight is a
    /// freshness signal independent of whether the stale snapshot changes
    /// visible sidebar state. It should coalesce to one follow-up probe.
    @Test func inFlightFilesystemEventChainsOneProbeRerun() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "feature/x",
            isDirty: true
        )
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(
            metadata: .repository(branch: "feature/x", isDirty: true),
            gated: true
        )
        let service = makeService(host: host, reader: reader, clock: clock)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        while await reader.probedDirectories.isEmpty {
            await Task.yield()
        }

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        for _ in 0..<500 {
            if service.workspaceGitProbeRerunPending(for: key) { break }
            await Task.yield()
        }
        #expect(service.workspaceGitProbeRerunPending(for: key))
        await reader.openGate()

        for _ in 0..<500 {
            let immediateProbeSleeps = await clock.recordedDurations.filter { $0 == 0 }.count
            if immediateProbeSleeps >= 3 { break }
            await Task.yield()
        }
        let immediateProbeSleeps = await clock.recordedDurations.filter { $0 == 0 }.count

        #expect(immediateProbeSleeps == 3)
        service.clearWorkspaceGitProbes(workspaceId: workspaceId)
    }

    /// With PR polling disabled, a branch probe does not touch the PR seam.
    @Test func pollingDisabledSuppressesPullRequestScheduling() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = false
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let clock = ManualGitPollClock()
        let pullRequestProbing = RecordingPullRequestProbing()
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "main")),
            clock: clock,
            pullRequestProbing: pullRequestProbing
        )

        let events = host.projectionEvents()
        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()

        for await event in events {
            if case .gitBranch = event { break }
        }
        #expect(pullRequestProbing.scheduledRefreshes.isEmpty)
    }

    /// A probe whose panel directory changes while the snapshot is in flight
    /// is dropped: no projection lands for the stale directory.
    @Test func directoryChangeWhileProbeInFlightDropsTheApply() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/old")
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(
            metadata: .repository(branch: "main"),
            gated: true
        )
        let service = makeService(host: host, reader: reader, clock: clock)

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()

        // Wait until the snapshot probe has started reading, then move the
        // panel to a different directory before letting the read finish.
        while await reader.probedDirectories.isEmpty {
            await Task.yield()
        }
        host.workspaces[0].state.panels[panelId]?.directory = "/tmp/new"
        await reader.openGate()

        // The stale apply must clear the probe rather than project "main".
        while !service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty {
            await Task.yield()
        }
        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)
        #expect(!host.events.contains { event in
            if case .gitBranch = event { return true }
            return false
        })
    }

    /// Disabling the git watch setting tears the subsystem down: all sidebar
    /// git metadata cleared and the PR seam reset.
    @Test func disablingWatchSettingClearsMetadataAndResetsPullRequests() async throws {
        let host = RecordingSidebarGitHost()
        host.addWorkspace(panelDirectory: "/tmp/repo")
        let pullRequestProbing = RecordingPullRequestProbing()
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .nonRepository),
            clock: ManualGitPollClock(),
            pullRequestProbing: pullRequestProbing
        )

        host.watchEnabled = false
        service.sidebarGitMetadataWatchSettingsDidChange()

        #expect(host.events.contains(.clearAllGitMetadata))
        #expect(pullRequestProbing.resetCount == 1)
    }

    /// Closing a workspace clears its probe state and PR tracking.
    @Test func clearWorkspaceGitProbesDropsTrackingForThatWorkspace() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let clock = ManualGitPollClock()
        let pullRequestProbing = RecordingPullRequestProbing()
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .nonRepository, gated: true),
            clock: clock,
            pullRequestProbing: pullRequestProbing
        )

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )
        await clock.waitForSleeper()
        #expect(!service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty)

        service.clearWorkspaceGitProbes(workspaceId: workspaceId)

        #expect(service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty)
        #expect(pullRequestProbing.clearedTrackingWorkspaceIds == [workspaceId])
    }
}
