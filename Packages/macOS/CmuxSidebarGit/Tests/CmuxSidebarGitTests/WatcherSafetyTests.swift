import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct WatcherSafetyTests {
    private func makeService(
        host: RecordingSidebarGitHost,
        metadataReader: any WorkspaceGitMetadataReading = GatedMetadataReader(
            metadata: .repository(branch: "main")
        ),
        descriptorReader: any GitMetadataWatchDescriptorReading = GitMetadataService(),
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) -> SidebarGitMetadataService {
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: metadataReader,
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
        creationWatchPaths: [String] = [],
        creationWatchAllowedRoots: [String] = []
    ) -> GitWorkspaceMetadataWatchDescriptor {
        GitWorkspaceMetadataWatchDescriptor(
            repositoryRoot: repositoryRoot,
            watchedPaths: [repositoryRoot],
            gitMetadataPaths: [repositoryRoot + "/.git/index"],
            trackedEntryPaths: [repositoryRoot + "/Sources/App.swift"],
            acceptsAllWorkTreeEvents: false,
            eventCoalescingInterval: .milliseconds(250),
            eventFilterIdentity: identity,
            degradation: degradation,
            creationWatchPaths: creationWatchPaths,
            creationWatchAllowedRoots: creationWatchAllowedRoots
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
        let creationWatchAncestor = URL(fileURLWithPath: "/tmp")
            .resolvingSymlinksInPath()
            .path
        #expect(
            service.workspaceGitMetadataCreationWatchersByAncestor[creationWatchAncestor] != nil
        )
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
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "shared-ancestor",
            degradation: .boundedGitStatus(entryCount: 2, directEntryLimit: 1),
            creationWatchPaths: [firstPath, secondPath]
        ))
        var logIterator = logEvents.makeAsyncIterator()
        _ = try #require(await logIterator.next())

        #expect(service.workspaceGitMetadataCreationWatchersByAncestor.count == 1)
        let creationWatchAncestor = configDirectory
            .resolvingSymlinksInPath()
            .path
        #expect(
            service.workspaceGitMetadataCreationWatchTargetsByAncestor[creationWatchAncestor]
                == Set([firstPath, secondPath])
        )
        service.stopWorkspaceGitMetadataWatcher(for: key)
    }

    @Test(.timeLimit(.minutes(1)))
    func passiveBranchChangeForcesCreationWatchDescriptorRefresh() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
        let metadataReader = GatedMetadataReader(
            metadata: .repository(branch: "feature/conditional-config"),
            gated: true
        )
        let (logEvents, logContinuation) = AsyncStream<String>.makeStream()
        defer { logContinuation.finish() }
        let service = makeService(
            host: host,
            metadataReader: metadataReader,
            descriptorReader: descriptorReader,
            debugLog: { logContinuation.yield($0) }
        )
        service.workspaceGitTrackedDirectoryByKey[key] = fixture.root.path

        service.updateWorkspaceGitMetadataWatcher(for: key, directory: fixture.root.path)
        #expect(await descriptorReader.nextRequestedDirectory() == fixture.root.path)
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "initial",
            degradation: .boundedGitStatus(entryCount: 2, directEntryLimit: 1)
        ))
        var logIterator = logEvents.makeAsyncIterator()
        _ = try #require(await logIterator.next())

        service.updateSurfaceGitBranch(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: "feature/conditional-config",
            isDirty: false
        )

        #expect(await descriptorReader.nextRequestedDirectory() == fixture.root.path)
        await descriptorReader.resumeNext(with: nil)
        await metadataReader.openGate()
        service.resetAllWorkspaceGitProbeTracking()
        service.stopWorkspaceGitMetadataWatcher(for: key)
    }

    @Test func symlinkedCreationWatchAncestorNeverWatchesFilesystemRoot() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let symlink = fixture.root.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: "/"
        )
        let targetPath = symlink.appendingPathComponent("future.inc").path
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
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
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "symlinked-root",
            degradation: .boundedGitStatus(entryCount: 2, directEntryLimit: 1),
            creationWatchPaths: [targetPath]
        ))
        var logIterator = logEvents.makeAsyncIterator()
        _ = try #require(await logIterator.next())

        #expect(service.workspaceGitMetadataCreationWatchersByAncestor.isEmpty)
        service.stopWorkspaceGitMetadataWatcher(for: key)
    }

    @Test func symlinkedCreationWatchKeepsLogicalParentWatcher() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let resolvedDirectory = fixture.root.appendingPathComponent(
            "resolved-config",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: resolvedDirectory,
            withIntermediateDirectories: true
        )
        let logicalLink = fixture.root.appendingPathComponent("logical-link")
        try FileManager.default.createSymbolicLink(
            atPath: logicalLink.path,
            withDestinationPath: resolvedDirectory.path
        )
        let targetPath = logicalLink.appendingPathComponent("future.inc").path
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
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
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "logical-symlink",
            degradation: .boundedGitStatus(entryCount: 2, directEntryLimit: 1),
            creationWatchPaths: [targetPath]
        ))
        var logIterator = logEvents.makeAsyncIterator()
        _ = try #require(await logIterator.next())

        let logicalParent = fixture.root.path
        #expect(
            service.workspaceGitMetadataCreationWatchersByAncestor[logicalParent] != nil
        )
        #expect(service.workspaceGitMetadataCreationWatchersByAncestor.count == 2)
        service.stopWorkspaceGitMetadataWatcher(for: key)
    }

    @Test(.timeLimit(.minutes(1)))
    func configCreatedBeforeWatcherRegistrationForcesDescriptorRefresh() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let configPath = fixture.root.appendingPathComponent("appeared.inc")
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
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
        try "[remote \"origin\"]\n".write(
            to: configPath,
            atomically: true,
            encoding: .utf8
        )
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "creation-race",
            degradation: .boundedGitStatus(entryCount: 2, directEntryLimit: 1),
            creationWatchPaths: [configPath.path]
        ))
        var logIterator = logEvents.makeAsyncIterator()
        _ = try #require(await logIterator.next())

        #expect(await descriptorReader.nextRequestedDirectory() == fixture.root.path)
        await descriptorReader.resumeNext(with: nil)
        service.resetAllWorkspaceGitProbeTracking()
    }

    @Test(.timeLimit(.minutes(1)))
    func symlinkRetargetRebindsTheResolvedCreationWatcher() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let firstTargetDirectory = fixture.root.appendingPathComponent(
            "first-target",
            isDirectory: true
        )
        let secondTargetDirectory = fixture.root.appendingPathComponent(
            "second-target",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstTargetDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondTargetDirectory,
            withIntermediateDirectories: true
        )
        let logicalLink = fixture.root.appendingPathComponent("retarget-link")
        try FileManager.default.createSymbolicLink(
            atPath: logicalLink.path,
            withDestinationPath: firstTargetDirectory.path
        )
        let targetPath = logicalLink.appendingPathComponent("future.inc").path
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
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
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "retarget-first",
            degradation: .boundedGitStatus(entryCount: 2, directEntryLimit: 1),
            creationWatchPaths: [targetPath]
        ))
        var logIterator = logEvents.makeAsyncIterator()
        _ = try #require(await logIterator.next())

        try FileManager.default.removeItem(at: logicalLink)
        try FileManager.default.createSymbolicLink(
            atPath: logicalLink.path,
            withDestinationPath: secondTargetDirectory.path
        )
        #expect(await descriptorReader.nextRequestedDirectory() == fixture.root.path)
        service.workspaceGitMetadataDegradationLoggedRepositoryRoots.remove(fixture.root.path)
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "retarget-second",
            degradation: .boundedGitStatus(entryCount: 2, directEntryLimit: 1),
            creationWatchPaths: [targetPath]
        ))
        _ = try #require(await logIterator.next())

        let resolvedSecondTarget = secondTargetDirectory.resolvingSymlinksInPath().path
        #expect(
            service.workspaceGitMetadataCreationWatcherAncestorByTargetPath[targetPath]
                == resolvedSecondTarget
        )
        service.stopWorkspaceGitMetadataWatcher(for: key)
    }

    @Test func externalCreationWatchAncestorIsRejected() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let targetPath = "/private/var/cmux-external-\(UUID().uuidString)/future.inc"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
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
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "external-scope",
            degradation: .boundedGitStatus(entryCount: 2, directEntryLimit: 1),
            creationWatchPaths: [targetPath]
        ))
        var logIterator = logEvents.makeAsyncIterator()
        _ = try #require(await logIterator.next())

        #expect(service.workspaceGitMetadataCreationWatchersByAncestor.isEmpty)
        service.stopWorkspaceGitMetadataWatcher(for: key)
    }

    @Test func siblingHomeCreationWatchAncestorIsRejected() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let targetPath = "/Users/cmux-other-\(UUID().uuidString)/future.inc"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
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
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "sibling-home",
            degradation: .boundedGitStatus(entryCount: 2, directEntryLimit: 1),
            creationWatchPaths: [targetPath]
        ))
        var logIterator = logEvents.makeAsyncIterator()
        _ = try #require(await logIterator.next())

        #expect(service.workspaceGitMetadataCreationWatchersByAncestor.isEmpty)
        service.stopWorkspaceGitMetadataWatcher(for: key)
    }

    @Test(.timeLimit(.minutes(1)))
    func descriptorCreationWatchRootsAllowConfiguredGitHomeOnly() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let configuredHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-configured-home-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: configuredHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configuredHome) }
        let allowedTarget = configuredHome.appendingPathComponent("future.inc").path
        let rejectedTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-creation-outside-\(UUID().uuidString)")
            .appendingPathComponent("future.inc")
            .path
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
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
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "configured-home-scope",
            degradation: .boundedGitStatus(entryCount: 2, directEntryLimit: 1),
            creationWatchPaths: [allowedTarget, rejectedTarget],
            creationWatchAllowedRoots: [configuredHome.path]
        ))
        var logIterator = logEvents.makeAsyncIterator()
        _ = try #require(await logIterator.next())

        let allowedAncestor = configuredHome.resolvingSymlinksInPath().path
        #expect(
            service.workspaceGitMetadataCreationWatchersByAncestor[allowedAncestor] != nil
        )
        #expect(
            service.workspaceGitMetadataCreationWatchTargetsByAncestor[allowedAncestor]
                == Set([allowedTarget])
        )
        #expect(
            !(service.workspaceGitMetadataCreationWatchPathsByProbeKey[key] ?? [])
                .contains(rejectedTarget)
        )
        service.stopWorkspaceGitMetadataWatcher(for: key)
    }
}
