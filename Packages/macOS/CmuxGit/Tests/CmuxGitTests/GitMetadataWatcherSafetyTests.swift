import Dispatch
import Foundation
import Testing
@testable import CmuxGit

/// Thread-safe through `lock`; unchecked because the compiler cannot infer the
/// synchronization protecting this test fake's mutable call count.
private final class RecordingGitDirtyStatusReader: GitDirtyStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let result: Bool?

    init(result: Bool?) {
        self.result = result
    }

    func isDirty(workTreeRoot: String) -> Bool? {
        lock.lock()
        calls += 1
        lock.unlock()
        return result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@Suite struct GitMetadataWatcherSafetyTests {
    /// Ignored build trees are absent from Git's index, so the tracked-file
    /// walker must never visit them while deriving the sidebar dirty bit.
    @Test func ignoredTreeIsNotVisitedByTrackedStatusWalk() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let trackedEntry = try fixture.writeWorkingTreeFile("Sources/App.swift", contents: "let value = 1\n")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [trackedEntry]))

        let ignoredRoot = fixture.root.appendingPathComponent("node_modules/pkg/build", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoredRoot, withIntermediateDirectories: true)
        try "node_modules/\n.build/\n".write(
            to: fixture.root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        for index in 0..<32 {
            try "generated".write(
                to: ignoredRoot.appendingPathComponent("artifact-\(index).js"),
                atomically: true,
                encoding: .utf8
            )
        }

        let reader = CountingGitFileStatusReader()
        let service = GitMetadataService(fileStatusReader: reader)
        let metadata = await service.workspaceMetadata(for: fixture.root.path)
        let trackedPath = fixture.root.appendingPathComponent("Sources/App.swift").path

        #expect(metadata.isRepository)
        #expect(!metadata.isDirty)
        #expect(reader.totalCallCount == 1)
        #expect(reader.visitedPaths == [trackedPath])
    }

    @Test func watchDescriptorRejectsIgnoredBuildOutputEvents() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let trackedEntry = try fixture.writeWorkingTreeFile("Sources/App.swift", contents: "let value = 1\n")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [trackedEntry]))
        let service = GitMetadataService()

        let descriptor = try #require(await service.watchDescriptor(for: fixture.root.path))
        let trackedFile = fixture.root.appendingPathComponent("Sources/App.swift").path
        let trackedDirectory = fixture.root.appendingPathComponent("Sources").path
        let ignoredOutput = fixture.root.appendingPathComponent("node_modules/pkg/build/output.js").path
        let index = fixture.gitDirectory.appendingPathComponent("index").path

        #expect(descriptor.containsRelevantChange(path: trackedFile))
        #expect(descriptor.containsRelevantChange(path: trackedDirectory))
        #expect(descriptor.containsRelevantChange(path: index))
        #expect(!descriptor.containsRelevantChange(path: ignoredOutput))
    }

    @Test func oversizedWatchDescriptorRetainsRateLimitedWorkTreeEvents() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let safetyConfiguration = GitMetadataSafetyConfiguration()
        let entryCount = safetyConfiguration.trackedEventPathCount + 1
        try fixture.writeDeclaredIndex(entryCount: entryCount)
        let service = GitMetadataService()

        let descriptor = try #require(await service.watchDescriptor(for: fixture.root.path))
        let ignoredOutput = fixture.root.appendingPathComponent("node_modules/pkg/output.js").path

        #expect(descriptor.watchedPaths.contains(fixture.root.path))
        #expect(descriptor.acceptsAllWorkTreeEvents)
        #expect(descriptor.eventCoalescingInterval == .seconds(30))
        #expect(descriptor.containsRelevantChange(path: ignoredOutput))
        #expect(descriptor.degradation == .unfilteredWorkTreeEvents(
            entryCount: entryCount,
            trackedPathLimit: safetyConfiguration.trackedEventPathCount,
            indexByteCount: 32,
            indexByteLimit: safetyConfiguration.directIndexByteCount,
            throttleSeconds: 30
        ))
    }

    @Test func forcedRootPreservesExistingSpecificDegradation() throws {
        let fixture = try GitRepositoryFixture()
        let degradation = GitWorkspaceMetadataWatchDegradation.unfilteredWorkTreeEvents(
            entryCount: 10,
            trackedPathLimit: 9,
            indexByteCount: 32,
            indexByteLimit: 1_024,
            throttleSeconds: 30
        )
        let descriptor = GitWorkspaceMetadataWatchDescriptor(
            repositoryRoot: fixture.root.path,
            watchedPaths: [fixture.gitDirectory.path],
            gitMetadataPaths: [fixture.gitDirectory.path],
            trackedEntryPaths: [],
            acceptsAllWorkTreeEvents: true,
            eventCoalescingInterval: .seconds(30),
            eventFilterIdentity: nil,
            degradation: degradation
        )

        let rebuilt = GitMetadataService().applyingForcedWorkTreeRoots(
            descriptor,
            repositories: [fixture.root.path]
        )

        #expect(rebuilt.forcedWorkTreeRoots == [fixture.root.path])
        #expect(rebuilt.degradation == degradation)
    }

    @Test func unreadableIndexDisablesWorkTreeEventsUntilMetadataChanges() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeRawIndex(Data("not a git index".utf8))
        let service = GitMetadataService()

        let descriptor = try #require(await service.watchDescriptor(for: fixture.root.path))
        let indexPath = fixture.gitDirectory.appendingPathComponent("index").path
        let workTreeChange = fixture.root.appendingPathComponent("Sources/App.swift").path

        #expect(!descriptor.watchedPaths.contains(fixture.root.path))
        #expect(descriptor.watchedPaths.contains(indexPath))
        #expect(!descriptor.acceptsAllWorkTreeEvents)
        #expect(!descriptor.containsRelevantChange(path: workTreeChange))
        #expect(descriptor.containsRelevantChange(path: indexPath))
        #expect(descriptor.degradation == .unreadableIndex)
    }

    @Test func expiredWatchPlanStillBuildsConservativeDescriptor() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let now = DispatchTime.now().uptimeNanoseconds
        let expiredDeadline = DispatchTime(
            uptimeNanoseconds: now > 1_000_000 ? now - 1_000_000 : 0
        )
        let inputs = GitMetadataWatchInputs(
            deadline: expiredDeadline,
            configPathsByRepository: [:],
            watchOnlyPathsByRepository: [:],
            metadataSentinelPathsByRepository: [:],
            indexSnapshotsByRepository: [:],
            forceWorkTreeRootRepositories: [repository.workTreeRoot]
        )

        let descriptor = await GitMetadataService().watchDescriptorBlocking(
            for: fixture.root.path,
            repository: repository,
            safetyConfiguration: GitMetadataSafetyConfiguration(),
            watchInputs: inputs
        )

        #expect(descriptor != nil)
    }

    @Test func forcedRootRebuildsOnlyForGitMetadataEvents() throws {
        let root = "/tmp/cmux-forced-root"
        let descriptor = GitWorkspaceMetadataWatchDescriptor(
            repositoryRoot: root,
            watchedPaths: [root],
            gitMetadataPaths: [],
            trackedEntryPaths: [],
            forcedWorkTreeRoots: [root],
            acceptsAllWorkTreeEvents: true,
            eventCoalescingInterval: .seconds(30),
            eventFilterIdentity: nil,
            degradation: .unreadableIndex
        )

        #expect(descriptor.containsGitMetadataChange(paths: [root + "/.git/config"]))
        #expect(!descriptor.containsGitMetadataChange(paths: [root + "/Sources/App.swift"]))
        #expect(!descriptor.containsGitMetadataChange(paths: [root + "/.git/objects/pack/a.pack"]))
    }

    @Test func sha256RepositoriesUseBoundedStatusFallbackForDirtyState() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [extensions]
            objectFormat = sha256
        """)
        try fixture.writeRawIndex(Data("sha256 index bytes".utf8))
        let dirtyStatusReader = RecordingGitDirtyStatusReader(result: true)
        let service = GitMetadataService(
            fileStatusReader: CountingGitFileStatusReader(),
            dirtyStatusReader: dirtyStatusReader
        )

        let metadata = await service.workspaceMetadata(for: fixture.root.path)

        #expect(metadata.isDirty)
        #expect(dirtyStatusReader.callCount == 1)
    }

    @Test func gitlinkPlanningRejectsIndexAboveByteBudgetBeforeParsing() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let submoduleRoot = fixture.root.appendingPathComponent("Dependencies/Child", isDirectory: true)
        let submoduleGitDirectory = submoduleRoot.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: submoduleGitDirectory,
            withIntermediateDirectories: true
        )
        let indexData = GitIndexFixture(
            version: 2,
            entries: [GitIndexFixture.Entry(path: "Dependencies/Child", mode: 0o160000)]
        ).data()
        try fixture.writeRawIndex(indexData)
        let safetyConfiguration = GitMetadataSafetyConfiguration(
            directIndexByteCount: indexData.count - 1,
            trackedEventPathCount: 10
        )

        let descriptor = try #require(GitMetadataService.workspaceGitMetadataWatchDescriptor(
            for: fixture.root.path,
            safetyConfiguration: safetyConfiguration
        ))
        let submoduleHeadPath = submoduleGitDirectory.appendingPathComponent("HEAD").path

        #expect(!descriptor.gitMetadataPaths.contains(submoduleHeadPath))
        #expect(descriptor.acceptsAllWorkTreeEvents)
    }

    /// One repository refresh has a hard direct-stat ceiling. Repositories over
    /// that ceiling must degrade instead of walking the entire index in-process.
    @Test(.timeLimit(.minutes(1)))
    func oversizedIndexDoesNotRunAnUnboundedDirectStatusWalk() async throws {
        let directVisitLimit = 4_096
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entries = (0...directVisitLimit).map { index in
            GitIndexFixture.Entry(
                path: String(format: "Sources/generated/%05d.swift", index),
                mtimeSeconds: 1,
                size: 0
            )
        }
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: entries))

        let cleanStatus = GitFileStatus(
            mode: UInt32(S_IFREG) | 0o644,
            size: 0,
            mtimeSeconds: 1,
            mtimeNanoseconds: 0
        )
        let reader = CountingGitFileStatusReader(defaultStatus: cleanStatus)
        let dirtyStatusReader = RecordingGitDirtyStatusReader(result: true)
        let (logEvents, logContinuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var logIterator = logEvents.makeAsyncIterator()
        let degradationRecorder = GitMetadataDegradationRecorder { message in
            logContinuation.yield(message)
        }
        let service = GitMetadataService(
            fileStatusReader: reader,
            dirtyStatusReader: dirtyStatusReader,
            degradationRecorder: degradationRecorder
        )

        let metadata = await service.workspaceMetadata(for: fixture.root.path)
        let degradationMessage = try #require(await logIterator.next())
        logContinuation.finish()

        #expect(metadata.isRepository)
        #expect(metadata.isDirty)
        #expect(
            reader.totalCallCount <= directVisitLimit,
            "A sidebar refresh must never lstat every entry of an oversized index."
        )
        #expect(dirtyStatusReader.callCount == 1)
        #expect(degradationMessage.contains("workspace.gitStatus.degraded"))
        #expect(degradationMessage.contains("tracked-entry-limit"))
        #expect(!degradationMessage.contains(fixture.root.path))
    }
}
