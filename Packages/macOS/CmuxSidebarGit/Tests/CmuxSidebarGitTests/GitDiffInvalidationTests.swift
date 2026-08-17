import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct GitDiffInvalidationTests {
    private func makeService(
        host: RecordingSidebarGitHost,
        reader: GatedMetadataReader,
        clock: ManualGitPollClock
    ) -> SidebarGitMetadataService {
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: reader,
            gitMetadataService: GitMetadataService(),
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 2),
            clock: clock
        )
        service.attach(host: host)
        return service
    }

    private func waitUntil(maxYields: Int = 5_000, _ predicate: () -> Bool) async -> Bool {
        for _ in 0..<maxYields {
            if predicate() {
                return true
            }
            await Task.yield()
        }
        return predicate()
    }

    private func waitUntilBufferContains(
        _ service: SidebarGitMetadataService,
        directory: String,
        timeout: Duration = .seconds(5)
    ) async {
        let deadline = ContinuousClock.now + timeout
        while service.workspaceGitDiffInvalidationBuffer[directory] == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Registering `.git` demand with left-sidebar polling disabled keeps a
    /// watcher alive and forwards filesystem events into the invalidation stream.
    @Test(.timeLimit(.minutes(1)))
    func registerDemandWithPollingDisabledKeepsWatcherAndStreamsEvents() async throws {
        let fixture = try GitRepositoryFixture()
        let directory = fixture.root.path
        let host = RecordingSidebarGitHost()
        host.gitMetadataActivity = .disabled
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .nonRepository),
            clock: ManualGitPollClock()
        )

        let stream = service.diffInvalidations()
        service.registerGitDiffDemand(for: directory)

        #expect(await waitUntil { service.workspaceGitMetadataWatchersByWatchedPathsKey.count == 1 })
        #expect(service.workspaceGitDiffDemandDirectories == [directory])

        // A filesystem change on a watched path lands in the invalidation buffer.
        try fixture.writeWorkingTreeFile("probe.txt", contents: "x")
        await waitUntilBufferContains(service, directory: directory)
        #expect(service.workspaceGitDiffInvalidationBuffer[directory]?.directory == directory)

        // The same event was delivered to the subscribed stream.
        var iterator = stream.makeAsyncIterator()
        let delivered = await iterator.next()
        #expect(delivered?.directory == directory)
    }

    /// Unregistering the last demand for a directory tears the watcher down.
    @Test func unregisterTearsDownWatcher() async throws {
        let fixture = try GitRepositoryFixture()
        let directory = fixture.root.path
        let host = RecordingSidebarGitHost()
        host.gitMetadataActivity = .disabled
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .nonRepository),
            clock: ManualGitPollClock()
        )

        service.registerGitDiffDemand(for: directory)
        #expect(await waitUntil { service.workspaceGitMetadataWatchersByWatchedPathsKey.count == 1 })

        service.unregisterGitDiffDemand(for: directory)

        #expect(service.workspaceGitDiffDemandDirectories.isEmpty)
        #expect(service.workspaceGitMetadataWatchersByWatchedPathsKey.isEmpty)
    }

    /// Registering the same directory twice dedupes to a single watcher.
    @Test func twoRegistersDedupeToOneWatcher() async throws {
        let fixture = try GitRepositoryFixture()
        let directory = fixture.root.path
        let host = RecordingSidebarGitHost()
        host.gitMetadataActivity = .disabled
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .nonRepository),
            clock: ManualGitPollClock()
        )

        service.registerGitDiffDemand(for: directory)
        service.registerGitDiffDemand(for: directory)

        #expect(await waitUntil { service.workspaceGitMetadataWatchersByWatchedPathsKey.count == 1 })
        #expect(service.workspaceGitDiffDemandDirectories == [directory])
    }

    /// The invalidation buffer dedupes per directory: repeated coalesced
    /// events for one directory collapse to a single buffered event, replayed
    /// exactly once to a new subscriber.
    @Test func invalidationsCoalescePerDirectory() async throws {
        let fixture = try GitRepositoryFixture()
        let directory = fixture.root.path
        let host = RecordingSidebarGitHost()
        host.gitMetadataActivity = .disabled
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .nonRepository),
            clock: ManualGitPollClock()
        )

        service.registerGitDiffDemand(for: directory)
        #expect(await waitUntil { service.workspaceGitMetadataWatchersByWatchedPathsKey.count == 1 })
        let watchedPathsKey = try #require(
            service.workspaceGitDiffDemandDirectoriesByWatchedPathsKey.keys.first
        )

        // Two coalesced filesystem events for the same directory.
        service.recordWorkspaceGitMetadataFilesystemEvent(forWatchedPathsKey: watchedPathsKey)
        service.recordWorkspaceGitMetadataFilesystemEvent(forWatchedPathsKey: watchedPathsKey)

        // The buffer holds one event per directory.
        #expect(service.workspaceGitDiffInvalidationBuffer.count == 1)
        #expect(service.workspaceGitDiffInvalidationBuffer[directory]?.directory == directory)

        // A fresh subscriber replays exactly that one event immediately.
        let stream = service.diffInvalidations()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.directory == directory)
    }
}
