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

    private func waitUntil(maxYields: Int = 5_000, _ predicate: () -> Bool) async -> Bool {
        for _ in 0..<maxYields {
            if predicate() {
                return true
            }
            await Task.yield()
        }
        return predicate()
    }

    private func makePullRequestService(
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

    private func pullRequestTraversalReads(_ host: RecordingSidebarGitHost) -> [Int] {
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

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()

        #expect(await waitUntil {
            host.events.contains { event in
                if case .gitBranch(workspaceId, panelId, "feature/x", true) = event {
                    return true
                }
                return false
            }
        })
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

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()

        #expect(await waitUntil {
            host.events.contains { event in
                if case .gitBranch = event { return true }
                return false
            }
        })
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

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "restore"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe())
        #expect(await waitUntil { pullRequestProbing.scheduledRefreshes.count == 1 })

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

        for expectedApplyCount in 1...2 {
            service.scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: workspaceId,
                panelId: panelId,
                reason: "filesystemEvent"
            )
            await clock.waitForSleeper(duration: 0)
            #expect(await clock.resumeFirst(duration: 0))
            #expect(await waitUntil {
                host.events.filter { event in
                    if case .gitBranch(workspaceId, panelId, branch, false) = event { return true }
                    return false
                }.count == expectedApplyCount
            })
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
        #expect(await waitUntil {
            host.workspaces[0].state.panels.values.filter {
                $0.branch?.branch == "feature/batched"
            }.count == 2
        })
        #expect(await waitUntil { host.orderedWorkspaceIdsReadCount >= 1 })

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

        for expectedApplyCount in 1...2 {
            service.scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: workspaceId,
                panelId: panelId,
                reason: "filesystemEvent"
            )
            await gitClock.waitForSleeper(duration: 0)
            #expect(await gitClock.resumeFirst(duration: 0))
            #expect(await waitUntil {
                host.events.filter { event in
                    if case .gitBranch(workspaceId, panelId, "feature/one", false) = event { return true }
                    return false
                }.count == expectedApplyCount
            })
            if expectedApplyCount == 1 {
                #expect(await waitUntil { host.orderedWorkspaceIdsReadCount == 1 })
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
        #expect(await waitUntil { host.orderedWorkspaceIdsReadCount == 3 })
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

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await gitClock.waitForSleeper(duration: 0)
        #expect(await gitClock.resumeFirst(duration: 0))
        #expect(await waitUntil {
            host.workspaces[0].state.panels[panelId]?.branch == SidebarPanelGitBranch(
                branch: "feature/x",
                isDirty: false
            ) && host.orderedWorkspaceIdsReadCount == 1
        })

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
