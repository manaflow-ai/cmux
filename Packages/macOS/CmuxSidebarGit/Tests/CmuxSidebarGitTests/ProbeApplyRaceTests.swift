import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct ProbeApplyRaceTests {
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

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            try? await clock.sleep(for: .milliseconds(1))
        }
        return predicate()
    }

    @Test(.timeLimit(.minutes(1)))
    func remoteTrustWhileProbeInFlightDropsLocalSnapshotApply() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        host.workspaces[0].state.isRemote = true
        let clock = ManualGitPollClock()
        let pullRequestProbing = RecordingPullRequestProbing()
        let reader = GatedMetadataReader(metadata: .repository(branch: "local-main"), gated: true)
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
        #expect(await reader.waitForProbe())

        host.workspaces[0].state.panels[panelId]?.hasTrustedRemoteDirectory = true
        await reader.openGate()

        #expect(await waitUntil {
            service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty
        })
        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)
        #expect(!host.events.contains { event in
            if case .gitBranch = event { return true }
            return false
        })
        #expect(pullRequestProbing.scheduledRefreshes.isEmpty)
        #expect(pullRequestProbing.clearedTrackingKeys.contains {
            $0.workspaceId == workspaceId && $0.panelId == panelId
        })
    }
}
