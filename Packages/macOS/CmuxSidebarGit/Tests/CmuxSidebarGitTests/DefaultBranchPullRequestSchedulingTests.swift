import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct DefaultBranchPullRequestSchedulingTests {
    private func makeService(
        host: RecordingSidebarGitHost,
        reader: GatedMetadataReader,
        clock: ManualGitPollClock,
        pullRequestProbing: RecordingPullRequestProbing
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
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    /// Default branches never need a PR lookup. Leaving them untracked must not
    /// make every metadata retry enqueue the same no-op refresh again.
    @Test(.timeLimit(.minutes(1)))
    func defaultBranchSnapshotDoesNotSchedulePullRequestRefresh() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        host.workspaces[0].state.panels[panelId]?.badge = SidebarPullRequestBadge(
            number: 42,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/42")!,
            status: .open,
            branch: "feature/old"
        )
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "main"))
        let pullRequestProbing = RecordingPullRequestProbing()
        pullRequestProbing.trackedPanelIdsByWorkspace[workspaceId] = [panelId]
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
            host.workspaces[0].state.panels[panelId]?.branch?.branch == "main"
        })
        #expect(pullRequestProbing.scheduledRefreshes.isEmpty)
        #expect(host.workspaces[0].state.panels[panelId]?.badge == nil)
        #expect(pullRequestProbing.clearedTrackingKeys.contains {
            $0.workspaceId == workspaceId && $0.panelId == panelId
        })
    }
}
