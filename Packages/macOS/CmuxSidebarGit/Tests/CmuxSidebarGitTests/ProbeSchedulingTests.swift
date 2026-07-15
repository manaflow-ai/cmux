import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct ProbeSchedulingTests {
    func makeService(
        host: RecordingSidebarGitHost,
        reader: GatedMetadataReader,
        clock: ManualGitPollClock,
        pullRequestProbing: any PullRequestProbing = RecordingPullRequestProbing()
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

    func waitUntil(
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

    func makePullRequestService(
        host: RecordingSidebarGitHost,
        clock: ManualGitPollClock = ManualGitPollClock()
    ) -> PullRequestPollService {
        let service = PullRequestPollService(
            gitMetadataService: GitMetadataService(),
            probeService: PullRequestProbeService(commandRunner: ForbiddenCommandRunner()),
            clock: clock
        )
        service.attach(host: host)
        return service
    }

    func pullRequestTraversalReads(_ host: RecordingSidebarGitHost) -> [Int] {
        [
            host.orderedWorkspaceIdsReadCount,
            host.panelGitBranchPanelIdsReadCount,
            host.panelPullRequestPanelIdsReadCount,
        ]
    }

    /// The initial probe's retry offsets [0, 0.5, 1.5, 3, 6, 10] are absolute
    /// offsets from scheduling time, walked as sequential clock gaps. The
    /// reader gate stays closed so no snapshot applies mid-walk (an applied
    /// non-repo snapshot would legitimately finish the probe and cancel the
    /// remaining retries).
    @Test func initialProbeWalksRetryOffsetsAsSequentialGaps() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/probe-test")
        host.workspaces[0].state.isRemote = true
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

    /// A remote terminal panel never schedules the initial local probe.
    @Test func remoteTerminalPanelSkipsInitialProbe() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/remote")
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.isRemoteTerminal = true
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

    @Test func remoteWorkspaceBranchReportDoesNotScheduleLocalProbe() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/remote")
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.hasTrustedRemoteDirectory = true
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "local-main", isDirty: true))
        let pullRequestProbing = RecordingPullRequestProbing()
        let service = makeService(
            host: host,
            reader: reader,
            clock: clock,
            pullRequestProbing: pullRequestProbing
        )
        service.updateSurfaceGitBranch(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: "remote-main",
            isDirty: false
        )

        #expect(host.workspaces[0].state.panels[panelId]?.branch == SidebarPanelGitBranch(
            branch: "remote-main",
            isDirty: false
        ))
        service.refreshTrackedWorkspaceGitMetadata(reason: "fallbackTimer")
        #expect(await clock.recordedDurations.isEmpty)
        #expect(await reader.probedDirectories.isEmpty)
        #expect(service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty)
        #expect(pullRequestProbing.scheduledRefreshes.isEmpty)
    }

    @Test func remotePwdPreservesMetadataReportedBeforeFirstTrustedDirectory() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.isRemoteTerminal = true
        let clock = ManualGitPollClock()
        let pullRequestProbing = RecordingPullRequestProbing()
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "local-main")),
            clock: clock,
            pullRequestProbing: pullRequestProbing
        )
        let badge = SidebarPullRequestBadge(
            number: 7277,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/7277")!,
            status: .open,
            branch: "remote-main"
        )

        service.updateSurfaceGitBranch(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: "remote-main",
            isDirty: false
        )
        host.updatePanelPullRequest(workspaceId: workspaceId, panelId: panelId, badge: badge)
        service.updateRemoteSurfaceDirectory(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: "/srv/project",
            displayLabel: nil
        )

        #expect(host.workspaces[0].state.panels[panelId]?.branch == SidebarPanelGitBranch(
            branch: "remote-main",
            isDirty: false
        ))
        #expect(host.workspaces[0].state.panels[panelId]?.badge == badge)
        #expect(pullRequestProbing.scheduledRefreshes.isEmpty)
        #expect(!host.events.contains(.clearGitBranch(workspaceId, panelId)))
        #expect(!host.events.contains(.clearPullRequestBadge(workspaceId, panelId)))
    }

    @Test func trustedRemoteDirectoryChangeClearsStaleMetadataWithoutLocalProbe() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/srv/old")
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.hasTrustedRemoteDirectory = true
        host.workspaces[0].state.panels[panelId]?.isRemoteTerminal = true
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "old-main",
            isDirty: true
        )
        let badge = SidebarPullRequestBadge(
            number: 7000,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/7000")!,
            status: .open,
            branch: "old-main"
        )
        host.workspaces[0].state.panels[panelId]?.badge = badge
        let clock = ManualGitPollClock()
        let pullRequestProbing = RecordingPullRequestProbing()
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "local-main")),
            clock: clock,
            pullRequestProbing: pullRequestProbing
        )

        service.updateSurfaceDirectory(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: "/srv/new",
            displayLabel: nil
        )

        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)
        #expect(host.workspaces[0].state.panels[panelId]?.badge == nil)
        #expect(host.events.contains(.clearGitBranch(workspaceId, panelId)))
        #expect(host.events.contains(.clearPullRequestBadge(workspaceId, panelId)))
        service.refreshTrackedWorkspaceGitMetadata(reason: "fallbackTimer")
        #expect(await clock.recordedDurations.isEmpty)
        #expect(pullRequestProbing.scheduledRefreshes.isEmpty)
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
        var projectionEvents = host.projectionEvents().makeAsyncIterator()

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()

        var observedProjection = false
        while let event = await projectionEvents.next() {
            if case .gitBranch(workspaceId, panelId, "feature/x", true) = event {
                observedProjection = true
                break
            }
        }
        #expect(observedProjection)
        #expect(host.workspaces[0].state.panels[panelId]?.branch == SidebarPanelGitBranch(branch: "feature/x", isDirty: true))
        #expect(pullRequestProbing.scheduledRefreshes.contains {
            $0.workspaceId == workspaceId && $0.panelId == panelId && $0.reason == "localGitProbe"
        })
    }

    /// Poll tracking restored without a local source identity is insufficient
    /// to dedupe the first snapshot. That snapshot seeds ownership exactly
    /// once so later directory or branch comparisons are well-defined.
    @Test(.timeLimit(.minutes(1)))
    func trackedBranchWithoutSourceIdentitySeedsPullRequestRefreshOnce() async throws {
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
        var projectionEvents = host.projectionEvents().makeAsyncIterator()

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()

        var observedProjection = false
        while let event = await projectionEvents.next() {
            if case .gitBranch = event {
                observedProjection = true
                break
            }
        }
        #expect(observedProjection)
        #expect(host.workspaces[0].state.panels[panelId]?.branch == SidebarPanelGitBranch(
            branch: "feature/x",
            isDirty: true
        ))
        #expect(pullRequestProbing.scheduledRefreshes.count == 1)
        #expect(pullRequestProbing.scheduledRefreshes.first?.reason == "localGitProbe")
    }

    /// Restored sessions can already have a branch projected before the first
    /// local git probe runs. If the PR poller has no tracking state yet, that
    /// same-branch snapshot must still seed one refresh.
    @Test(.timeLimit(.minutes(1)))
    func restoredKnownBranchSnapshotSeedsPullRequestRefreshWhenUntracked() async throws {
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
        var projectionEvents = host.projectionEvents().makeAsyncIterator()

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "restore"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe())
        while let event = await projectionEvents.next() {
            if case .gitBranch = event { break }
        }

        #expect(pullRequestProbing.scheduledRefreshes.count == 1)
        let scheduledRefresh = try #require(pullRequestProbing.scheduledRefreshes.first)
        #expect(scheduledRefresh.workspaceId == workspaceId)
        #expect(scheduledRefresh.panelId == panelId)
        #expect(scheduledRefresh.reason == "localGitProbe")
    }

    /// Default branches intentionally own no PR poll deadline. Reapplying an
    /// unchanged local snapshot must still remember that source, avoid the
    /// global refresh traversal, and clear an old badge only once.
    @Test(.timeLimit(.minutes(1)), arguments: [" main ", " master "])
    func repeatedDefaultBranchSnapshotSuppressesPullRequestReseedingAndClearsBadgeOnce(
        rawBranch: String
    ) async throws {
        let branch = try #require(GitMetadataService.normalizedBranchName(rawBranch))
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        host.workspaces[0].state.panels[panelId]?.badge = SidebarPullRequestBadge(
            number: 42,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/42")!,
            status: .open,
            branch: branch
        )
        let clock = ManualGitPollClock()
        let pullRequestService = makePullRequestService(host: host)
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: rawBranch)),
            clock: clock,
            pullRequestProbing: pullRequestService
        )
        var projectionEvents = host.projectionEvents().makeAsyncIterator()

        for _ in 1...2 {
            service.scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: workspaceId,
                panelId: panelId,
                reason: "filesystemEvent"
            )
            await clock.waitForSleeper(duration: 0)
            #expect(await clock.resumeFirst(duration: 0))
            var observedProjection = false
            while let event = await projectionEvents.next() {
                if case .gitBranch(workspaceId, panelId, branch, false) = event {
                    observedProjection = true
                    break
                }
            }
            #expect(observedProjection)
        }

        let badgeClearCount = host.events.filter { event in
            if case .clearPullRequestBadge(workspaceId, panelId) = event { return true }
            return false
        }.count
        #expect(badgeClearCount == 1)
        #expect(host.orderedWorkspaceIdsReadCount == 0)
        #expect(host.panelGitBranchPanelIdsReadCount == 0)
        #expect(host.panelPullRequestPanelIdsReadCount == 0)
    }

}
