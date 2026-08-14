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

    /// One repository refresh has a hard direct-stat ceiling. Repositories over
    /// that ceiling must degrade instead of walking the entire index in-process.
    @Test func oversizedIndexDoesNotRunAnUnboundedDirectStatusWalk() async throws {
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
        let service = GitMetadataService(
            fileStatusReader: reader,
            dirtyStatusReader: dirtyStatusReader
        )

        let metadata = await service.workspaceMetadata(for: fixture.root.path)

        #expect(metadata.isRepository)
        #expect(metadata.isDirty)
        #expect(
            reader.totalCallCount <= directVisitLimit,
            "A sidebar refresh must never lstat every entry of an oversized index."
        )
        #expect(dirtyStatusReader.callCount == 1)
    }
}
