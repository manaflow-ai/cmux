import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct WatcherConstructionIsolationTests {
    @Test(.timeLimit(.minutes(1)))
    func filesystemWatcherConstructionDoesNotRunOnMainThread() async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-watcher-\(UUID().uuidString)", isDirectory: true)
        let gitURL = repositoryURL.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitURL, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: gitURL.appendingPathComponent("HEAD"))
        try Data().write(to: gitURL.appendingPathComponent("index"))
        try Data("[core]\n\trepositoryformatversion = 0\n".utf8)
            .write(to: gitURL.appendingPathComponent("config"))
        defer { try? FileManager.default.removeItem(at: repositoryURL) }

        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: repositoryURL.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let threadProbe = WatcherConstructionThreadProbe()
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: GatedMetadataReader(metadata: .notARepository),
            gitMetadataService: GitMetadataService(),
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 1),
            clock: ManualGitPollClock(),
            workspaceGitMetadataWatcherFactory: { _ in
                let isMainThread = Thread.isMainThread
                Task { await threadProbe.record(isMainThread) }
                return nil
            }
        )
        service.attach(host: host)
        service.workspaceGitTrackedDirectoryByKey[key] = repositoryURL.path

        service.updateWorkspaceGitMetadataWatcher(for: key, directory: repositoryURL.path)
        let watcherConstructedOnMainThread = await threadProbe.next()

        #expect(!watcherConstructedOnMainThread)
    }
}
