import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite(.serialized)
struct PullRequestPollServiceBatchBypassTests {
    private func makeRepository(at root: URL, index: Int) throws -> String {
        let repository = root.appendingPathComponent("repo-\(index)", isDirectory: true)
        let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gitDirectory,
            withIntermediateDirectories: true
        )
        try Data("ref: refs/heads/feature/x\n".utf8).write(
            to: gitDirectory.appendingPathComponent("HEAD")
        )
        let config = """
        [core]
            repositoryformatversion = 0
            bare = false
        [remote "origin"]
            url = https://github.com/cmux-test-7856/repo-\(index).git
        """
        try Data(config.utf8).write(to: gitDirectory.appendingPathComponent("config"))
        return repository.path
    }

    /// A fresh-event burst can span more panels than one refresh batch. Every
    /// batch must reject stale repo cache data, including the timer-driven tail.
    @Test(.timeLimit(.minutes(1)))
    func cacheBypassSurvivesAcrossBatchLimit() async throws {
        URLProtocol.registerClass(EmptyPullRequestURLProtocol.self)
        defer { URLProtocol.unregisterClass(EmptyPullRequestURLProtocol.self) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pr-bypass-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        var keys: [WorkspaceGitProbeKey] = []
        for index in 0...PullRequestPollService.workspacePullRequestRefreshBatchLimit {
            let directory = try makeRepository(at: root, index: index)
            let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
            host.workspaces[index].state.panels[panelId]?.branch =
                SidebarPanelGitBranch(branch: "feature/x", isDirty: false)
            keys.append(WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId))
        }

        let clock = ManualGitPollClock()
        let service = PullRequestPollService(
            gitMetadataService: GitMetadataService(),
            probeService: PullRequestProbeService(commandRunner: ForbiddenCommandRunner()),
            clock: clock
        )
        service.attach(host: host)

        for (index, key) in keys.enumerated() {
            let slug = "cmux-test-7856/repo-\(index)"
            service.workspacePullRequestRepoCacheBySlug[slug] = WorkspacePullRequestRepoCacheEntry(
                fetchedAt: Date(),
                pullRequestsByBranch: [
                    "feature/x": GitHubPullRequestProbeItem(
                        number: 7_856 + index,
                        state: "OPEN",
                        url: "https://github.com/\(slug)/pull/\(7_856 + index)",
                        updatedAt: nil,
                        headRefName: "feature/x"
                    ),
                ]
            )
            service.scheduleWorkspacePullRequestRefresh(
                workspaceId: key.workspaceId,
                panelId: key.panelId,
                reason: "localGitProbe"
            )
        }

        let headKeys = keys.prefix(PullRequestPollService.workspacePullRequestRefreshBatchLimit)
        let tailKey = try #require(keys.last)
        let planningTask = try #require(service.workspacePullRequestScheduledRefreshTask)
        await planningTask.value
        if let refreshTask = service.workspacePullRequestRefreshTask {
            await refreshTask.value
        }
        #expect(service.workspacePullRequestRefreshTask == nil)
        #expect(headKeys.allSatisfy {
            service.workspacePullRequestNextPollAtByKey[$0].map { $0 > Date() } == true
        })
        #expect(service.workspacePullRequestNextPollAtByKey[tailKey] == .distantPast)
        #expect(service.workspacePullRequestBypassRepoCacheKeys == [tailKey])

        await clock.waitForSleeper()
        let pollTask = try #require(service.workspacePullRequestPollTask)
        await clock.resumeNext()
        await pollTask.value
        if let refreshTask = service.workspacePullRequestRefreshTask {
            await refreshTask.value
        }
        #expect(service.workspacePullRequestRefreshTask == nil)
        #expect(service.workspacePullRequestNextPollAtByKey[tailKey].map { $0 > Date() } == true)

        let tailPanel = try #require(host.workspaces.last?.state.panels[tailKey.panelId])
        #expect(tailPanel.badge == nil)
        #expect(service.workspacePullRequestBypassRepoCacheKeys.isEmpty)
    }

    @Test
    func resetClearsPendingCacheBypassBeforePlanning() {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
        host.workspaces[0].state.panels[panelId]?.branch =
            SidebarPanelGitBranch(branch: "feature/x", isDirty: false)
        let service = PullRequestPollService(
            gitMetadataService: GitMetadataService(),
            probeService: PullRequestProbeService(commandRunner: ForbiddenCommandRunner()),
            clock: ManualGitPollClock()
        )
        service.attach(host: host)

        service.scheduleWorkspacePullRequestRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "localGitProbe"
        )
        #expect(service.workspacePullRequestBypassRepoCacheKeys == [
            WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId),
        ])

        service.resetWorkspacePullRequestRefreshState()

        #expect(service.workspacePullRequestBypassRepoCacheKeys.isEmpty)
        #expect(service.workspacePullRequestScheduledRefreshTask == nil)
    }
}
