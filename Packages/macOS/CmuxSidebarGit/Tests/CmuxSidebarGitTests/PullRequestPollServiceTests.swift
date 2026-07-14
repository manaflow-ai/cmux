import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct PullRequestPollServiceTests {
    private func makeService(
        host: RecordingSidebarGitHost,
        clock: ManualGitPollClock
    ) -> PullRequestPollService {
        // ForbiddenCommandRunner proves no `gh auth token` subprocess runs in
        // these offline scenarios (panels without GitHub-resolvable
        // directories never reach the fetch stage).
        let service = PullRequestPollService(
            gitMetadataService: GitMetadataService(),
            probeService: PullRequestProbeService(commandRunner: ForbiddenCommandRunner()),
            clock: clock
        )
        service.attach(host: host)
        return service
    }

    private func badge(number: Int, status: PullRequestStatus, branch: String? = "feature/x") -> SidebarPullRequestBadge {
        SidebarPullRequestBadge(
            number: number,
            label: "PR",
            url: URL(string: "https://github.com/o/r/pull/\(number)")!,
            status: status,
            branch: branch
        )
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

    /// A synchronous burst of local-git source seeds plans one whole-window pass.
    /// The planner still marks every panel due, while avoiding one full scan per request.
    @Test func synchronousSourceSeedBurstCoalescesGlobalPlanning() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        var keys: [WorkspaceGitProbeKey] = []
        for _ in 0..<100 {
            let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
            host.workspaces[host.workspaces.count - 1].state.panels[panelId]?.branch =
                SidebarPanelGitBranch(branch: "feature/x", isDirty: false)
            keys.append(WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId))
        }
        let service = makeService(host: host, clock: ManualGitPollClock())

        for key in keys {
            service.seedWorkspacePullRequestRefreshIfNeeded(
                workspaceId: key.workspaceId,
                panelId: key.panelId,
                directory: "/tmp/repo",
                branch: "feature/x",
                reason: "localGitProbe"
            )
        }

        #expect(await waitUntil { host.orderedWorkspaceIdsReadCount >= 1 })
        #expect(host.orderedWorkspaceIdsReadCount == 1)
        #expect(keys.allSatisfy {
            service.workspacePullRequestNextPollAtByKey[$0] == .distantPast
        })
    }

    /// A refresh against a panel whose directory resolves to no GitHub repo
    /// applies `unsupportedRepository` (badge cleared) and re-arms the poll
    /// timer with the jittered background interval, floored at 0.25 seconds.
    @Test func unsupportedRepositoryClearsBadgeAndArmsJitteredPollDeadline() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(branch: "feature/x", isDirty: false)
        host.workspaces[0].state.panels[panelId]?.badge = badge(number: 7, status: .open)
        let clock = ManualGitPollClock()
        let service = makeService(host: host, clock: clock)

        let events = host.projectionEvents()
        service.scheduleWorkspacePullRequestRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )

        var cleared = false
        for await event in events {
            if case .clearPullRequestBadge(workspaceId, panelId) = event {
                cleared = true
                break
            }
        }
        #expect(cleared)
        #expect(host.workspaces[0].state.panels[panelId]?.badge == nil)

        // The next poll deadline: max(0.25, jittered 60s background interval).
        await clock.waitForSleeper()
        let armed = try #require(await clock.lastRecordedDuration)
        #expect(armed >= 0.25)
        #expect(armed <= 66.1)
        // The panel stays tracked for the next sweep.
        #expect(service.workspacePullRequestTrackedPanelIds(workspaceId: workspaceId) == [panelId])
    }

    /// `gh pr merge` hints flip an open badge to merged synchronously
    /// (optimistic reconcile before the verifying refresh lands).
    @Test func mergeCommandHintReconcilesOpenBadge() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
        host.workspaces[0].state.panels[panelId]?.badge = badge(number: 42, status: .open)
        let service = makeService(host: host, clock: ManualGitPollClock())

        service.handleWorkspacePullRequestCommandHint(
            workspaceId: workspaceId,
            panelId: panelId,
            action: "merge",
            target: "#42"
        )

        #expect(host.workspaces[0].state.panels[panelId]?.badge?.status == .merged)
        #expect(host.workspaces[0].state.panels[panelId]?.badge?.isStale == false)
    }

    /// A hint whose target names a different PR number does not reconcile.
    @Test func mismatchedCommandHintTargetIsIgnored() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
        host.workspaces[0].state.panels[panelId]?.badge = badge(number: 42, status: .open)
        let service = makeService(host: host, clock: ManualGitPollClock())

        service.handleWorkspacePullRequestCommandHint(
            workspaceId: workspaceId,
            panelId: panelId,
            action: "merge",
            target: "#41"
        )

        #expect(host.workspaces[0].state.panels[panelId]?.badge?.status == .open)
    }

    /// A PR-URL target matches by trailing path component.
    @Test func urlCommandHintTargetMatchesByNumber() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
        host.workspaces[0].state.panels[panelId]?.badge = badge(number: 42, status: .open)
        let service = makeService(host: host, clock: ManualGitPollClock())

        service.handleWorkspacePullRequestCommandHint(
            workspaceId: workspaceId,
            panelId: panelId,
            action: "close",
            target: "https://github.com/other/repo/pull/42"
        )

        #expect(host.workspaces[0].state.panels[panelId]?.badge?.status == .closed)
    }

    /// `reopen` only applies to a non-open badge.
    @Test func reopenCommandHintRestoresOpenStatus() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
        host.workspaces[0].state.panels[panelId]?.badge = badge(number: 42, status: .closed)
        let service = makeService(host: host, clock: ManualGitPollClock())

        service.handleWorkspacePullRequestCommandHint(
            workspaceId: workspaceId,
            panelId: panelId,
            action: "reopen",
            target: nil
        )

        #expect(host.workspaces[0].state.panels[panelId]?.badge?.status == .open)
    }

    /// Branches that skip lookup (e.g. main) clear the badge and tracking
    /// without ever starting a refresh.
    @Test func skippedLookupBranchClearsBadgeWithoutRefresh() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(branch: "main", isDirty: false)
        host.workspaces[0].state.panels[panelId]?.badge = badge(number: 7, status: .open, branch: "main")
        let clock = ManualGitPollClock()
        let service = makeService(host: host, clock: clock)

        // Only meaningful when the probe pipeline skips main-like branches.
        guard PullRequestProbeService.shouldSkipLookup(branch: "main") else { return }

        service.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "test")

        #expect(host.workspaces[0].state.panels[panelId]?.badge == nil)
        #expect(service.workspacePullRequestTrackedPanelIds(workspaceId: workspaceId).isEmpty)
        #expect(await clock.recordedDurations.isEmpty)
    }

    @Test func remoteWorkspaceBranchAndBadgeAreSkippedByPollingRefresh() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/remote")
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.hasTrustedRemoteDirectory = true
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(branch: "feature/x", isDirty: false)
        host.workspaces[0].state.panels[panelId]?.badge = badge(number: 7, status: .open)
        let clock = ManualGitPollClock()
        let service = makeService(host: host, clock: clock)

        service.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "test")

        #expect(host.workspaces[0].state.panels[panelId]?.badge?.number == 7)
        #expect(service.workspacePullRequestTrackedPanelIds(workspaceId: workspaceId).isEmpty)
        #expect(await clock.recordedDurations.isEmpty)
    }

    @Test func applySkipsPanelThatBecameRemoteTrustedDuringRefresh() throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/remote")
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(branch: "feature/x", isDirty: false)
        host.workspaces[0].state.panels[panelId]?.badge = badge(number: 7, status: .open)
        let service = makeService(host: host, clock: ManualGitPollClock())
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        service.workspacePullRequestProbeStateByKey[key] = .inFlight(rerunPending: false)
        service.workspacePullRequestNextPollAtByKey[key] = .distantPast
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.hasTrustedRemoteDirectory = true

        service.applyWorkspacePullRequestRefreshResults(
            [
                WorkspacePullRequestRefreshResult(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    resolution: .resolved(WorkspacePullRequestResolvedItem(
                        number: 99,
                        urlString: "https://github.com/o/r/pull/99",
                        statusRawValue: PullRequestStatus.open.rawValue,
                        branch: "feature/x"
                    )),
                    usedCachedRepoData: false
                ),
            ],
            repoResults: [:],
            requestedKeys: [key],
            now: Date(),
            reason: "test"
        )

        #expect(host.workspaces[0].state.panels[panelId]?.badge?.number == 7)
        #expect(!host.events.contains { event in
            if case .pullRequestBadge(_, _, let badge) = event { return badge.number == 99 }
            return false
        })
        #expect(service.workspacePullRequestTrackedPanelIds(workspaceId: workspaceId).isEmpty)
    }

    /// A local source change can arrive after a refresh has started but before
    /// its stale result applies. The queued source seed and stale-result rerun
    /// must collapse into one global traversal.
    @Test(.timeLimit(.minutes(1)))
    func staleApplyAndQueuedSourceSeedRunOneFollowUpTraversal() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "feature/a",
            isDirty: false
        )
        let service = makeService(host: host, clock: ManualGitPollClock())
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let sourceA = PullRequestPollService.SourceIdentity(
            directory: directory,
            branch: "feature/a"
        )

        service.workspacePullRequestSourceByKey[key] = sourceA
        service.workspacePullRequestProbeStateByKey[key] = .inFlight(rerunPending: false)
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "feature/b",
            isDirty: false
        )
        service.seedWorkspacePullRequestRefreshIfNeeded(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            branch: "feature/b",
            reason: "localGitProbe"
        )
        #expect(service.workspacePullRequestSeedRefreshTask != nil)

        let workspaceReadsBeforeApply = host.orderedWorkspaceIdsReadCount
        let branchReadsBeforeApply = host.panelGitBranchPanelIdsReadCount
        let badgeReadsBeforeApply = host.panelPullRequestPanelIdsReadCount
        service.applyWorkspacePullRequestRefreshResults(
            [],
            repoResults: [:],
            requestedKeys: [key],
            requestedSourceByKey: [key: sourceA],
            now: Date(),
            reason: "localGitProbe"
        )

        while service.workspacePullRequestSeedRefreshTask != nil {
            await Task.yield()
        }
        while service.workspacePullRequestRefreshTask != nil {
            await Task.yield()
        }

        #expect(host.orderedWorkspaceIdsReadCount == workspaceReadsBeforeApply + 1)
        #expect(host.panelGitBranchPanelIdsReadCount == branchReadsBeforeApply + 1)
        #expect(host.panelPullRequestPanelIdsReadCount == badgeReadsBeforeApply + 1)

        let workspaceReadsBeforeUnchangedSeed = host.orderedWorkspaceIdsReadCount
        service.seedWorkspacePullRequestRefreshIfNeeded(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            branch: " feature/b ",
            reason: "localGitProbe"
        )
        await Task.yield()
        #expect(host.orderedWorkspaceIdsReadCount == workspaceReadsBeforeUnchangedSeed)

        let workspaceReadsBeforeCommandHint = host.orderedWorkspaceIdsReadCount
        service.handleWorkspacePullRequestCommandHint(
            workspaceId: workspaceId,
            panelId: panelId,
            action: "merge",
            target: nil
        )
        #expect(host.orderedWorkspaceIdsReadCount == workspaceReadsBeforeCommandHint + 1)
        service.resetWorkspacePullRequestRefreshState()
    }

    @Test func resolvedBadgeWithMismatchedBranchSchedulesGitMetadataProbe() throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "feature/old",
            isDirty: false
        )
        let service = makeService(host: host, clock: ManualGitPollClock())
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)

        service.applyWorkspacePullRequestRefreshResults(
            [
                WorkspacePullRequestRefreshResult(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    resolution: .resolved(WorkspacePullRequestResolvedItem(
                        number: 99,
                        urlString: "https://github.com/o/r/pull/99",
                        statusRawValue: PullRequestStatus.open.rawValue,
                        branch: "feature/new"
                    )),
                    usedCachedRepoData: false
                ),
            ],
            repoResults: [:],
            requestedKeys: [key],
            now: Date(),
            reason: "test"
        )

        #expect(host.workspaces[0].state.panels[panelId]?.badge?.number == 99)
        #expect(host.events.contains(.scheduleGitMetadataProbe(
            workspaceId,
            panelId,
            "pullRequestBranchMismatch"
        )))
    }

    @Test func resolvedBadgeWithMatchingBranchDoesNotScheduleProbe() throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "feature/new",
            isDirty: false
        )
        let service = makeService(host: host, clock: ManualGitPollClock())
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)

        service.applyWorkspacePullRequestRefreshResults(
            [
                WorkspacePullRequestRefreshResult(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    resolution: .resolved(WorkspacePullRequestResolvedItem(
                        number: 99,
                        urlString: "https://github.com/o/r/pull/99",
                        statusRawValue: PullRequestStatus.open.rawValue,
                        branch: "feature/new"
                    )),
                    usedCachedRepoData: false
                ),
            ],
            repoResults: [:],
            requestedKeys: [key],
            now: Date(),
            reason: "test"
        )

        #expect(host.workspaces[0].state.panels[panelId]?.badge?.number == 99)
        #expect(!host.events.contains {
            if case .scheduleGitMetadataProbe = $0 { return true }
            return false
        })
    }

    /// With git metadata watching disabled, a branch mismatch must not nudge
    /// the probe scheduler: that path clears the panel's branch and the badge
    /// the same apply pass just wrote.
    @Test func resolvedBadgeMismatchDoesNotScheduleProbeWhenWatchDisabled() throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        host.watchEnabled = false
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let service = makeService(host: host, clock: ManualGitPollClock())
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)

        service.applyWorkspacePullRequestRefreshResults(
            [
                WorkspacePullRequestRefreshResult(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    resolution: .resolved(WorkspacePullRequestResolvedItem(
                        number: 99,
                        urlString: "https://github.com/o/r/pull/99",
                        statusRawValue: PullRequestStatus.open.rawValue,
                        branch: "feature/new"
                    )),
                    usedCachedRepoData: false
                ),
            ],
            repoResults: [:],
            requestedKeys: [key],
            now: Date(),
            reason: "test"
        )

        #expect(host.workspaces[0].state.panels[panelId]?.badge?.number == 99)
        #expect(!host.events.contains {
            if case .scheduleGitMetadataProbe = $0 { return true }
            return false
        })
    }

    /// Disabling polling resets all tracking and clears every badge.
    @Test func disablingPollingSettingClearsBadgesAndTracking() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
        host.workspaces[0].state.panels[panelId]?.badge = badge(number: 9, status: .open)
        let service = makeService(host: host, clock: ManualGitPollClock())

        host.pollingEnabled = false
        service.sidebarPullRequestPollingSettingsDidChange()

        #expect(host.events.contains(.clearAllPullRequestMetadata))
        #expect(host.workspaces[0].state.panels[panelId]?.badge == nil)
        #expect(service.workspacePullRequestTrackedPanelIds(workspaceId: workspaceId).isEmpty)
    }
}
