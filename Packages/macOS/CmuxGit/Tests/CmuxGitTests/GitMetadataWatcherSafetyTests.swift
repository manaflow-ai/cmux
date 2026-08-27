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
        #expect(reader.visitedPaths.contains(trackedPath))
        #expect(reader.visitedPaths.allSatisfy { !$0.hasPrefix(ignoredRoot.path) })
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

    @Test func missingConfigIncludeWatchesItsExistingParent() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [include]
            path = future-remotes.inc
        """)
        let descriptor = try #require(
            await GitMetadataService().watchDescriptor(for: fixture.root.path)
        )
        let missingPath = fixture.gitDirectory.appendingPathComponent("future-remotes.inc").path
        let gitDirectoryPath = fixture.gitDirectory.standardizedFileURL.path

        #expect(descriptor.gitMetadataPaths.contains(missingPath))
        #expect(descriptor.watchedPaths.contains(gitDirectoryPath))
        #expect(descriptor.containsGitMetadataChange(paths: [missingPath]))
    }

    @Test func missingExternalConfigIncludeNeverWatchesFilesystemRoot() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [include]
            path = /no-such-cmux-config-(UUID().uuidString)/future-remotes.inc
        """)

        let descriptor = try #require(
            await GitMetadataService().watchDescriptor(for: fixture.root.path)
        )

        #expect(!descriptor.watchedPaths.contains("/"))
    }

    @Test func missingXDGConfigDoesNotWatchItsBroadParent() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let xdgHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxgit-xdg-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: xdgHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: xdgHome) }

        let descriptor = try #require(
            GitMetadataService.workspaceGitMetadataWatchDescriptor(
                for: fixture.root.path,
                environment: [
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "XDG_CONFIG_HOME": xdgHome.path,
                ]
            )
        )

        #expect(!descriptor.watchedPaths.contains(xdgHome.path))
        #expect(!descriptor.watchedPaths.contains(xdgHome.deletingLastPathComponent().path))
    }

    @Test func missingGlobalConfigGetsASeparateCreationWatchPath() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let globalConfigURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxgit-missing-global-\(UUID().uuidString)")

        let descriptor = try #require(
            GitMetadataService.workspaceGitMetadataWatchDescriptor(
                for: fixture.root.path,
                environment: [
                    "GIT_CONFIG_GLOBAL": globalConfigURL.path,
                    "GIT_CONFIG_NOSYSTEM": "1",
                ]
            )
        )

        #expect(descriptor.creationWatchPaths.contains(globalConfigURL.path))
        #expect(!descriptor.watchedPaths.contains(globalConfigURL.deletingLastPathComponent().path))
    }

    @Test func missingExternalConfigDoesNotBecomeARecursiveHomeWatch() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let parent = home.appendingPathComponent(
            ".cmuxgit-watch-parent-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let missingPath = parent.appendingPathComponent("future.inc")
        let globalConfigURL = fixture.root.appendingPathComponent("global.gitconfig")
        try """
        [include]
            path = \(missingPath.path)
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)

        let descriptor = try #require(
            GitMetadataService.workspaceGitMetadataWatchDescriptor(
                for: fixture.root.path,
                environment: [
                    "GIT_CONFIG_GLOBAL": globalConfigURL.path,
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "HOME": home.path,
                ]
            )
        )

        #expect(!descriptor.watchedPaths.contains(parent.path))
        #expect(descriptor.creationWatchPaths.contains(missingPath.path))
    }

    @Test func symlinkedConfigWatchesResolvedTarget() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let targetURL = fixture.root.appendingPathComponent("shared-config")
        let configURL = fixture.gitDirectory.appendingPathComponent("config")
        try "[remote \"origin\"]\n\turl = https://github.com/owner/repo.git\n"
            .write(to: targetURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: configURL.path,
            withDestinationPath: targetURL.path
        )

        let descriptor = try #require(
            await GitMetadataService().watchDescriptor(for: fixture.root.path)
        )

        #expect(descriptor.watchedPaths.contains(targetURL.standardizedFileURL.path))
        #expect(descriptor.gitMetadataPaths.contains(targetURL.standardizedFileURL.path))
    }

    @Test func symlinkedConfigDirectoryNeverExpandsWatcherToFilesystemRoot() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let configURL = fixture.gitDirectory.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(
            atPath: configURL.path,
            withDestinationPath: "/"
        )

        let descriptor = try #require(
            await GitMetadataService().watchDescriptor(for: fixture.root.path)
        )

        #expect(!descriptor.watchedPaths.contains("/"))
        #expect(!descriptor.gitMetadataPaths.contains("/"))
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
