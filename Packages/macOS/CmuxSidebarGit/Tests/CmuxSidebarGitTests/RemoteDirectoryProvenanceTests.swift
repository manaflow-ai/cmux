import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct RemoteDirectoryProvenanceTests {
    @Test func repeatedTrustedDirectoryPreservesMetadataUntilPathChanges() async {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.isRemoteTerminal = true
        let reader = GatedMetadataReader(metadata: .repository(branch: "local-main"))
        let clock = ManualGitPollClock()
        let pullRequestProbing = RecordingPullRequestProbing()
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: reader,
            gitMetadataService: GitMetadataService(),
            pullRequestProbing: pullRequestProbing,
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 2),
            clock: clock
        )
        service.attach(host: host)
        service.updateRemoteSurfaceDirectory(
            workspaceId: workspaceId, panelId: panelId,
            directory: "/srv/project", displayLabel: nil
        )
        service.updateSurfaceGitBranch(
            workspaceId: workspaceId, panelId: panelId,
            branch: "remote-main", isDirty: false
        )
        let badge = SidebarPullRequestBadge(
            number: 7277, label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/7277")!,
            status: .open, branch: "remote-main"
        )
        host.updatePanelPullRequest(workspaceId: workspaceId, panelId: panelId, badge: badge)

        service.updateRemoteSurfaceDirectory(
            workspaceId: workspaceId, panelId: panelId,
            directory: "/srv/project", displayLabel: nil
        )
        #expect(host.workspaces[0].state.panels[panelId]?.branch?.branch == "remote-main")
        #expect(host.workspaces[0].state.panels[panelId]?.badge == badge)
        #expect(!host.events.contains(.clearGitBranch(workspaceId, panelId)))
        #expect(!host.events.contains(.clearPullRequestBadge(workspaceId, panelId)))

        service.updateRemoteSurfaceDirectory(
            workspaceId: workspaceId, panelId: panelId,
            directory: "/srv/other", displayLabel: nil
        )
        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)
        #expect(host.workspaces[0].state.panels[panelId]?.badge == nil)
        #expect(host.events.contains(.clearGitBranch(workspaceId, panelId)))
        #expect(host.events.contains(.clearPullRequestBadge(workspaceId, panelId)))
        #expect(pullRequestProbing.scheduledRefreshes.isEmpty)
        #expect(await clock.recordedDurations.isEmpty)
        #expect(await reader.probedDirectories.isEmpty)
    }
}
