import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

/// Thread-safe through `lock`; the unchecked conformance exists only because
/// `NSLock`-protected mutable storage cannot be proven Sendable by the compiler.
private final class SidebarGitLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ message: String) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }

    func contains(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.contains { $0.contains(text) }
    }
}

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
        let recorder = SidebarGitLogRecorder()
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: GatedMetadataReader(metadata: .repository(branch: "main")),
            gitMetadataService: GitMetadataService(),
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 1),
            clock: ManualGitPollClock(),
            debugLog: recorder.record
        )
        service.attach(host: host)
        service.workspaceGitTrackedDirectoryByKey[key] = fixture.root.path

        service.updateWorkspaceGitMetadataWatcher(for: key, directory: fixture.root.path)

        for _ in 0..<10_000 where !recorder.contains("workspace.gitWatch.degraded") {
            await Task.yield()
        }
        service.stopWorkspaceGitMetadataWatcher(for: key)

        #expect(
            recorder.contains("workspace.gitWatch.degraded"),
            "The safety valve must explain when and why a repository leaves direct-scan mode."
        )
    }
}
