import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

extension ProbeSchedulingTests {
    /// A snapshot batch can project several panels in one main-actor turn.
    /// Its PR seeds should produce one host traversal containing every panel,
    /// rather than one traversal for every apply callback.
    @Test(.timeLimit(.minutes(1)))
    func sameTurnFeatureSnapshotSeedsCoalesceToOnePullRequestTraversal() async throws {
        let directory = "/tmp/shared-repo"
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, firstPanelId) = host.addWorkspace(panelDirectory: directory)
        let secondPanelId = UUID()
        host.workspaces[0].state.panels[secondPanelId] = RecordingSidebarGitHost.PanelState(
            directory: directory
        )
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(
            metadata: .repository(branch: "feature/batched"),
            gated: true
        )
        let pullRequestService = makePullRequestService(host: host)
        let service = makeService(
            host: host,
            reader: reader,
            clock: clock,
            pullRequestProbing: pullRequestService
        )
        var projectionEvents = host.projectionEvents().makeAsyncIterator()

        for panelId in [firstPanelId, secondPanelId] {
            service.scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: workspaceId,
                panelId: panelId,
                reason: "filesystemEvent"
            )
        }
        for _ in 0..<2 {
            await clock.waitForSleeper()
            await clock.resumeNext()
        }
        await reader.openGate()
        var projectedPanelIds: Set<UUID> = []
        while projectedPanelIds.count < 2, let event = await projectionEvents.next() {
            if case .gitBranch(workspaceId, let panelId, "feature/batched", false) = event {
                projectedPanelIds.insert(panelId)
            }
        }
        #expect(projectedPanelIds == [firstPanelId, secondPanelId])
        await host.waitForOrderedWorkspaceIdsReadCount(1)

        #expect(host.orderedWorkspaceIdsReadCount == 1)
        #expect(host.panelGitBranchPanelIdsReadCount == 1)
        #expect(host.panelPullRequestPanelIdsReadCount == 1)
    }

    /// A feature source seeds once. Changing either half of its normalized
    /// directory/branch identity seeds once more, while a command hint remains
    /// an explicit force request even when that source is unchanged.
    @Test(.timeLimit(.minutes(1)))
    func featureSourceChangesSeedOnceAndCommandHintStillForces() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let gitClock = ManualGitPollClock()
        let pullRequestClock = ManualGitPollClock()
        let pullRequestService = makePullRequestService(host: host, clock: pullRequestClock)
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "feature/one")),
            clock: gitClock,
            pullRequestProbing: pullRequestService
        )
        var projectionEvents = host.projectionEvents().makeAsyncIterator()

        for expectedApplyCount in 1...2 {
            service.scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: workspaceId,
                panelId: panelId,
                reason: "filesystemEvent"
            )
            await gitClock.waitForSleeper(duration: 0)
            #expect(await gitClock.resumeFirst(duration: 0))
            var observedExpectedProjection = false
            while let event = await projectionEvents.next() {
                if case .gitBranch(workspaceId, panelId, "feature/one", false) = event {
                    observedExpectedProjection = true
                    break
                }
            }
            #expect(observedExpectedProjection)
            if expectedApplyCount == 1 {
                await host.waitForOrderedWorkspaceIdsReadCount(1)
            }
        }
        #expect(host.orderedWorkspaceIdsReadCount == 1)

        service.updateSurfaceDirectory(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: " file:///tmp/repo-two ",
            displayLabel: nil
        )
        #expect(host.orderedWorkspaceIdsReadCount == 2)
        service.updateSurfaceDirectory(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: "/tmp/repo-two",
            displayLabel: nil
        )
        #expect(host.orderedWorkspaceIdsReadCount == 2)

        service.updateSurfaceGitBranch(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: " feature/two ",
            isDirty: false
        )
        await host.waitForOrderedWorkspaceIdsReadCount(3)
        service.updateSurfaceGitBranch(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: "feature/two",
            isDirty: false
        )
        #expect(host.orderedWorkspaceIdsReadCount == 3)

        pullRequestService.handleWorkspacePullRequestCommandHint(
            workspaceId: workspaceId,
            panelId: panelId,
            action: "merge",
            target: nil
        )
        await host.waitForOrderedWorkspaceIdsReadCount(4)
        #expect(host.orderedWorkspaceIdsReadCount == 4)
    }

    /// A shell branch report can update only the dirty projection while its
    /// normalized repository source stays unchanged. That projection update
    /// must not force a PR traversal; command hints remain force requests.
    @Test(.timeLimit(.minutes(1)))
    func sameBranchDirtyOnlyUpdateDoesNotTraversePullRequestPoller() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let gitClock = ManualGitPollClock()
        let pullRequestService = makePullRequestService(host: host)
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "feature/x")),
            clock: gitClock,
            pullRequestProbing: pullRequestService
        )
        var projectionEvents = host.projectionEvents().makeAsyncIterator()

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await gitClock.waitForSleeper(duration: 0)
        #expect(await gitClock.resumeFirst(duration: 0))
        var observedInitialProjection = false
        while let event = await projectionEvents.next() {
            if case .gitBranch(workspaceId, panelId, "feature/x", false) = event {
                observedInitialProjection = true
                break
            }
        }
        #expect(observedInitialProjection)
        await host.waitForOrderedWorkspaceIdsReadCount(1)

        let readsBeforeDirtyUpdate = pullRequestTraversalReads(host)
        service.updateSurfaceGitBranch(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: " feature/x ",
            isDirty: true
        )

        #expect(host.workspaces[0].state.panels[panelId]?.branch == SidebarPanelGitBranch(
            branch: "feature/x",
            isDirty: true
        ))
        #expect(pullRequestTraversalReads(host) == readsBeforeDirtyUpdate)

        let readsBeforeCommandHint = pullRequestTraversalReads(host)
        pullRequestService.handleWorkspacePullRequestCommandHint(
            workspaceId: workspaceId,
            panelId: panelId,
            action: "merge",
            target: nil
        )
        await host.waitForOrderedWorkspaceIdsReadCount(readsBeforeCommandHint[0] + 1)
        #expect(pullRequestTraversalReads(host) == readsBeforeCommandHint.map { $0 + 1 })
    }

    /// A filesystem event that arrives while a probe is already in flight is a
    /// freshness signal independent of whether the stale snapshot changes
    /// visible sidebar state. It should coalesce to one follow-up probe.
    @Test(.timeLimit(.minutes(1)))
    func inFlightFilesystemEventChainsOneProbeRerun() async throws {
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
        #expect(await reader.waitForTrackedPathEventGenerationProbe())

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await waitUntil { service.workspaceGitProbeRerunPending(for: key) })
        #expect(service.workspaceGitProbeRerunPending(for: key))
        await reader.openGate()

        #expect(await clock.waitForRecordedDuration(0, count: 3))
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

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()

        #expect(await waitUntil {
            host.events.contains { event in
                if case .gitBranch = event { return true }
                return false
            }
        })
        #expect(pullRequestProbing.scheduledRefreshes.isEmpty)
    }

    /// A probe whose panel directory changes while the snapshot is in flight
    /// is dropped: no projection lands for the stale directory.
    @Test(.timeLimit(.minutes(1)))
    func directoryChangeWhileProbeInFlightDropsTheApply() async throws {
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
        #expect(await reader.waitForProbe())
        host.workspaces[0].state.panels[panelId]?.directory = "/tmp/new"
        await reader.openGate()

        // The stale apply must clear the probe rather than project "main".
        #expect(await waitUntil {
            service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty
        })
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
