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

    private func badge(
        number: Int,
        status: PullRequestStatus,
        branch: String? = "feature/x",
        ciStatus: PullRequestCIStatus = .neutral
    ) -> SidebarPullRequestBadge {
        SidebarPullRequestBadge(
            number: number,
            label: "PR",
            url: URL(string: "https://github.com/o/r/pull/\(number)")!,
            status: status,
            branch: branch,
            ciStatus: ciStatus
        )
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
        host.workspaces[0].state.panels[panelId]?.badge = badge(number: 42, status: .open, ciStatus: .success)
        let service = makeService(host: host, clock: ManualGitPollClock())

        service.handleWorkspacePullRequestCommandHint(
            workspaceId: workspaceId,
            panelId: panelId,
            action: "merge",
            target: "#42"
        )

        #expect(host.workspaces[0].state.panels[panelId]?.badge?.status == .merged)
        #expect(host.workspaces[0].state.panels[panelId]?.badge?.isStale == false)
        #expect(host.workspaces[0].state.panels[panelId]?.badge?.ciStatus == .neutral)
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

    /// Toggling only the CI-status setting invalidates the repo cache and
    /// forces tracked PR rows due without treating PR visibility as disabled.
    @Test func changingCIStatusSettingClearsRepoCacheAndForcesTrackedRowsDue() {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        host.mobileHostActive = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
        host.workspaces[0].state.panels[panelId]?.badge = badge(number: 9, status: .open)
        let service = makeService(host: host, clock: ManualGitPollClock())
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        service.workspacePullRequestNextPollAtByKey[key] = Date().addingTimeInterval(60)
        service.workspacePullRequestRepoCacheBySlug["o/r"] = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: Date(),
            pullRequestsByBranch: [:]
        )

        host.ciStatusEnabled = true
        service.sidebarPullRequestPollingSettingsDidChange()

        #expect(service.workspacePullRequestRepoCacheBySlug.isEmpty)
        #expect(service.workspacePullRequestNextPollAtByKey[key] == .distantPast)
        #expect(!host.events.contains(.clearAllPullRequestMetadata))
    }

    @Test func cachedRepoResultPersistsSupplementalCIStatusCoverage() {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let service = makeService(host: host, clock: ManualGitPollClock())
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let baseEntry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: fetchedAt,
            pullRequestsByBranch: [:]
        )
        let ciEntry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: fetchedAt,
            pullRequestsByBranch: [:],
            includesCIStatus: true,
            ciStatusByPullRequestNumber: [42: .success]
        )
        service.workspacePullRequestRepoCacheBySlug["o/r"] = baseEntry

        service.applyWorkspacePullRequestRefreshResults(
            [],
            repoResults: ["o/r": .success(ciEntry, usedCache: true, transientBranches: [])],
            requestedKeys: [],
            now: fetchedAt,
            reason: "test"
        )

        let stored = service.workspacePullRequestRepoCacheBySlug["o/r"]
        #expect(stored?.includesCIStatus == true)
        #expect(stored?.ciStatusByPullRequestNumber == [42: .success])
    }
}
