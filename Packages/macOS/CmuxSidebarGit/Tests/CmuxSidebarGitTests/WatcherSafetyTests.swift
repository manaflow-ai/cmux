import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct WatcherSafetyTests {
    private func makeService(
        host: RecordingSidebarGitHost,
        descriptorReader: any GitMetadataWatchDescriptorReading = GitMetadataService(),
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) -> SidebarGitMetadataService {
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: GatedMetadataReader(metadata: .repository(branch: "main")),
            gitMetadataService: descriptorReader,
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 1),
            clock: ManualGitPollClock(),
            debugLog: debugLog
        )
        service.attach(host: host)
        return service
    }

    private func descriptor(
        repositoryRoot: String,
        identity: String,
        degradation: GitWorkspaceMetadataWatchDegradation? = nil,
        creationWatchPaths: [String] = []
    ) -> GitWorkspaceMetadataWatchDescriptor {
        GitWorkspaceMetadataWatchDescriptor(
            repositoryRoot: repositoryRoot,
            watchedPaths: [repositoryRoot],
            gitMetadataPaths: [repositoryRoot + "/.git/index"],
            creationWatchPaths: creationWatchPaths,
            trackedEntryPaths: [repositoryRoot + "/Sources/App.swift"],
            acceptsAllWorkTreeEvents: false,
            eventCoalescingInterval: .milliseconds(250),
            eventFilterIdentity: identity,
            degradation: degradation
        )
    }

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
        let service = makeService(
            host: host,
            debugLog: { logContinuation.yield($0) }
        )
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

    /// A metadata event received while a descriptor read is in flight invalidates
    /// that result and schedules exactly one read of the newer repository state.
    @Test(.timeLimit(.minutes(1)))
    func metadataEventDuringDescriptorReadSchedulesReplacement() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
        let creationWatchPath = "/tmp/cmux-creation-watch-\(UUID().uuidString)"
        let (logEvents, logContinuation) = AsyncStream<String>.makeStream()
        defer { logContinuation.finish() }
        let service = makeService(
            host: host,
            descriptorReader: descriptorReader,
            debugLog: { logContinuation.yield($0) }
        )
        service.workspaceGitTrackedDirectoryByKey[key] = fixture.root.path

        service.updateWorkspaceGitMetadataWatcher(for: key, directory: fixture.root.path)
        #expect(await descriptorReader.nextRequestedDirectory() == fixture.root.path)

        for _ in 0..<5 {
            service.updateWorkspaceGitMetadataWatcher(
                for: key,
                directory: fixture.root.path,
                forceDescriptorRefresh: true
            )
        }
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "stale"
        ))

        #expect(await descriptorReader.nextRequestedDirectory() == fixture.root.path)
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "fresh",
            degradation: .boundedGitStatus(entryCount: 2, directEntryLimit: 1),
            creationWatchPaths: [creationWatchPath]
        ))

        var logIterator = logEvents.makeAsyncIterator()
        let appliedLog = try #require(await logIterator.next())
        let installedWatcherKey = try #require(
            service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key]
        )
        #expect(appliedLog.contains("workspace.gitWatch.degraded"))
        #expect(installedWatcherKey.eventFilterIdentity == "fresh")
        #expect(service.workspaceGitMetadataCreationWatchersByPath[creationWatchPath] != nil)
        #expect(await descriptorReader.requestCount == 2)
        service.stopWorkspaceGitMetadataWatcher(for: key)
    }

    /// Session restoration clears watcher state even after its probe state has
    /// already completed and no longer owns the key.
    @Test func globalResetStopsWatcherOnlyState() {
        let directory = "/tmp/watcher-only"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let watchedPathsKey = WorkspaceGitMetadataWatchedPathsKey(paths: [directory])
        let service = makeService(host: host)
        let (events, eventContinuation) = AsyncStream<Void>.makeStream()
        let refreshTask = Task {
            for await _ in events {}
        }
        defer {
            eventContinuation.finish()
            refreshTask.cancel()
        }

        service.workspaceGitTrackedDirectoryByKey[key] = directory
        service.setWorkspaceGitMetadataWatcherSourceDirectory(directory, for: key)
        service.setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: key)
        service.workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey[watchedPathsKey] = refreshTask
        service.workspaceGitMetadataWatcherDescriptorRequestsByKey[key] =
            WorkspaceGitMetadataWatcherDescriptorRequest(generation: 1, directory: directory)
        service.workspaceGitMetadataWatcherDescriptorInvalidatedKeys.insert(key)

        service.resetAllWorkspaceGitProbeTracking()

        #expect(service.workspaceGitMetadataWatcherSourceDirectoryByKey.isEmpty)
        #expect(service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey.isEmpty)
        #expect(service.workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey.isEmpty)
        #expect(service.workspaceGitMetadataWatcherDescriptorRequestsByKey.isEmpty)
        #expect(service.workspaceGitMetadataWatcherDescriptorInvalidatedKeys.isEmpty)
        #expect(refreshTask.isCancelled)
    }

    @Test func missingConfigTargetsShareOneAncestorWatcher() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let configDirectory = fixture.root.appendingPathComponent("config-watch", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let firstPath = configDirectory.appendingPathComponent("first.inc").path
        let secondPath = configDirectory.appendingPathComponent("second.inc").path
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
        let service = makeService(host: host, descriptorReader: descriptorReader)
        service.workspaceGitTrackedDirectoryByKey[key] = fixture.root.path

        service.updateWorkspaceGitMetadataWatcher(for: key, directory: fixture.root.path)
        #expect(await descriptorReader.nextRequestedDirectory() == fixture.root.path)
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "shared-ancestor",
            creationWatchPaths: [firstPath, secondPath]
        ))

        #expect(service.workspaceGitMetadataCreationWatchersByPath.count == 1)
        service.stopWorkspaceGitMetadataWatcher(for: key)
    }
}
