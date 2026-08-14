import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct WatcherSafetyTests {
    /// Crossing the tracked-file threshold is observable: the watcher degrades
    /// to a bounded strategy and emits one clear diagnostic naming that choice.
    @Test(.timeLimit(.minutes(1)))
    func oversizedRepositoryWatcherLogsItsDegradedMode() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 4_097)
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let (logEvents, logContinuation) = AsyncStream<String>.makeStream()
        defer { logContinuation.finish() }
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: GatedMetadataReader(metadata: .repository(branch: "main")),
            gitMetadataService: GitMetadataService(),
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 1),
            clock: ManualGitPollClock(),
            debugLog: { logContinuation.yield($0) }
        )
        service.attach(host: host)
        service.workspaceGitTrackedDirectoryByKey[key] = fixture.root.path

        service.updateWorkspaceGitMetadataWatcher(for: key, directory: fixture.root.path)

        var logIterator = logEvents.makeAsyncIterator()
        var matchingLog: String?
        while matchingLog == nil, let message = await logIterator.next() {
            if message.contains("workspace.gitWatch.degraded") {
                matchingLog = message
            }
        }
        service.stopWorkspaceGitMetadataWatcher(for: key)

        let degradedLog = try #require(
            matchingLog,
            "The safety valve must explain when and why a repository leaves direct-scan mode."
        )
        #expect(
            !degradedLog.contains(fixture.root.path),
            "Safety-valve diagnostics must not expose repository paths."
        )
    }
}
