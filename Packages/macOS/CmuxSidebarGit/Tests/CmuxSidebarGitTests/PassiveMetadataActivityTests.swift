import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct PassiveMetadataActivityTests {
    @Test func passiveRemoteReportsSurviveHiddenRowsAndReenable() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/srv/project")
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.isRemoteTerminal = true
        let clock = ManualGitPollClock()
        let pullRequestProbing = RecordingPullRequestProbing()
        let reader = GatedMetadataReader(metadata: .nonRepository)
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: reader,
            gitMetadataService: GitMetadataService(),
            pullRequestProbing: pullRequestProbing,
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 2),
            clock: clock
        )
        service.attach(host: host)

        service.updateSurfaceGitBranch(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: "before-hide",
            isDirty: false
        )
        host.gitMetadataActivity = .passiveReportsOnly
        service.sidebarGitMetadataWatchSettingsDidChange()
        service.updateSurfaceGitBranch(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: "reported-while-hidden",
            isDirty: true
        )

        #expect(host.workspaces[0].state.panels[panelId]?.branch == SidebarPanelGitBranch(
            branch: "reported-while-hidden",
            isDirty: true
        ))
        #expect(!host.events.contains(.clearAllGitMetadata))
        #expect(await reader.probedDirectories.isEmpty)
        #expect(pullRequestProbing.scheduledRefreshes.isEmpty)

        host.gitMetadataActivity = .activePolling
        service.sidebarGitMetadataWatchSettingsDidChange()

        #expect(host.workspaces[0].state.panels[panelId]?.branch?.branch == "reported-while-hidden")
        #expect(await reader.probedDirectories.isEmpty)
    }
}
