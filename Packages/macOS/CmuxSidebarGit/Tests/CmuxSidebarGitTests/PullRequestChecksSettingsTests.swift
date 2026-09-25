import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct PullRequestChecksSettingsTests {
    @Test func disablingChecksClearsProjectionAndRejectsAnOldResult() {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        host.pullRequestChecksEnabled = true
        let (workspace, panel) = host.addWorkspace(panelDirectory: nil)
        let service = PullRequestPollService(
            gitMetadataService: GitMetadataService(),
            probeService: PullRequestProbeService(commandRunner: ForbiddenCommandRunner()),
            clock: ManualGitPollClock()
        )
        service.attach(host: host)
        let summary = PullRequestChecksSummary(status: .success, checks: [], mergeStatus: .ready)
        host.updatePanelPullRequest(workspaceId: workspace, panelId: panel, badge: SidebarPullRequestBadge(
            number: 1, label: "PR", url: URL(string: "https://github.com/o/r/pull/1")!,
            status: .open, branch: "feature/x", checks: summary
        ))
        host.pullRequestChecksEnabled = false
        host.mobileHostActive = true
        service.sidebarPullRequestPollingSettingsDidChange()
        #expect(host.panelPullRequestBadge(workspaceId: workspace, panelId: panel)?.checks == nil)
        host.mobileHostActive = false
        service.applyWorkspacePullRequestRefreshResults([
            WorkspacePullRequestRefreshResult(
                workspaceId: workspace, panelId: panel,
                resolution: .resolved(WorkspacePullRequestResolvedItem(
                    number: 1, urlString: "https://github.com/o/r/pull/1", statusRawValue: "open",
                    branch: "feature/x", checks: summary
                )), usedCachedRepoData: false
            )
        ], repoResults: [:], requestedKeys: [WorkspaceGitProbeKey(workspaceId: workspace, panelId: panel)], now: Date(), reason: "test")
        #expect(host.panelPullRequestBadge(workspaceId: workspace, panelId: panel)?.checks == nil)
        service.resetWorkspacePullRequestRefreshState()
    }

    @Test func clearedProjectionRequiresFreshAssociationAndChecks() {
        let host = RecordingSidebarGitHost()
        host.pullRequestChecksEnabled = true
        let (workspace, panel) = host.addWorkspace(panelDirectory: nil)
        let service = PullRequestPollService(
            gitMetadataService: GitMetadataService(),
            probeService: PullRequestProbeService(commandRunner: ForbiddenCommandRunner()),
            clock: ManualGitPollClock()
        )
        service.attach(host: host)
        let key = WorkspaceGitProbeKey(workspaceId: workspace, panelId: panel)
        #expect(service.requiresFreshPullRequestChecks(for: [key]))
        host.updatePanelPullRequest(workspaceId: workspace, panelId: panel, badge: SidebarPullRequestBadge(
            number: 1, label: "PR", url: URL(string: "https://github.com/o/r/pull/1")!, status: .open,
            checks: PullRequestChecksSummary(status: .success, checks: [], mergeStatus: .ready)
        ))
        #expect(!service.requiresFreshPullRequestChecks(for: [key]))
        host.pullRequestChecksEnabled = false
        #expect(!service.requiresFreshPullRequestChecks(for: [key]))
    }

    @Test func unavailableChecksKeepTheNormalPullRequestCacheEligible() {
        let host = RecordingSidebarGitHost()
        host.pullRequestChecksEnabled = true
        let (workspace, panel) = host.addWorkspace(panelDirectory: nil)
        let service = PullRequestPollService(
            gitMetadataService: GitMetadataService(),
            probeService: PullRequestProbeService(commandRunner: ForbiddenCommandRunner()),
            clock: ManualGitPollClock()
        )
        service.attach(host: host)
        host.updatePanelPullRequest(workspaceId: workspace, panelId: panel, badge: SidebarPullRequestBadge(
            number: 1, label: "PR", url: URL(string: "https://github.com/o/r/pull/1")!, status: .open,
            checks: PullRequestChecksSummary(status: .unavailable, checks: [], mergeStatus: .unknown)
        ))
        #expect(!service.requiresFreshPullRequestChecks(for: [WorkspaceGitProbeKey(workspaceId: workspace, panelId: panel)]))
        service.resetWorkspacePullRequestRefreshState()
    }

    @Test func enablingChecksMakesAlreadyTrackedPullRequestsDue() {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspace, panel) = host.addWorkspace(panelDirectory: nil)
        let service = PullRequestPollService(
            gitMetadataService: GitMetadataService(),
            probeService: PullRequestProbeService(commandRunner: ForbiddenCommandRunner()),
            clock: ManualGitPollClock()
        )
        service.attach(host: host)
        let key = WorkspaceGitProbeKey(workspaceId: workspace, panelId: panel)
        service.workspacePullRequestNextPollAtByKey[key] = .distantFuture
        host.mobileHostActive = true
        host.pullRequestChecksEnabled = true
        service.sidebarPullRequestPollingSettingsDidChange()
        #expect(service.shouldRefreshWorkspacePullRequest(key: key, now: Date(), currentPullRequest: nil))
        service.resetWorkspacePullRequestRefreshState()
    }
}
