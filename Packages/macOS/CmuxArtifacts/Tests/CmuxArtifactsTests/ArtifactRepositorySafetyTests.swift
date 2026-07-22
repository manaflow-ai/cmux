import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact repository safety")
struct ArtifactRepositorySafetyTests {
    @Test("Provenance rejects valid metadata with mismatched identity")
    func rejectsMismatchedProvenanceIdentity() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let paths = ArtifactStorePaths(projectRoot: root)
        try FileManager.default.createDirectory(
            at: paths.provenanceRoot,
            withIntermediateDirectories: true
        )
        let metadataURL = paths.provenanceRoot.appendingPathComponent("digest.json")

        for (embeddedDigest, embeddedSize) in [("other-digest", Int64(4)), ("digest", Int64(5))] {
            let existing = ArtifactMetadataDocument(
                version: 1,
                digest: embeddedDigest,
                lastKnownRelativePath: "old/path.md",
                size: embeddedSize,
                events: []
            )
            let existingData = try JSONEncoder().encode(existing)
            try existingData.write(to: metadataURL)

            #expect(throws: ArtifactStoreError.corruptProvenance(metadataURL.path)) {
                try recorder.record(
                    paths: paths,
                    digest: "digest",
                    relativePath: "workspace/session/plan.md",
                    size: 4,
                    event: event
                )
            }
            #expect(try Data(contentsOf: metadataURL) == existingData)
        }
    }

    @Test("Corrupt provenance is preserved instead of overwritten")
    func preservesCorruptProvenance() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let paths = ArtifactStorePaths(projectRoot: root)
        try FileManager.default.createDirectory(
            at: paths.provenanceRoot,
            withIntermediateDirectories: true
        )
        let metadataURL = paths.provenanceRoot.appendingPathComponent("digest.json")
        let corruptData = Data("{truncated".utf8)
        try corruptData.write(to: metadataURL)

        #expect(throws: ArtifactStoreError.corruptProvenance(metadataURL.path)) {
            try recorder.record(
                paths: paths,
                digest: "digest",
                relativePath: "workspace/session/plan.md",
                size: 4,
                event: event
            )
        }
        #expect(try Data(contentsOf: metadataURL) == corruptData)
    }

    @Test("Repository rejects corrupt provenance before moving another file")
    func rejectsCorruptProvenanceBeforePersistence() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write(
            "same bytes",
            named: "plan.md",
            under: root.appendingPathComponent("outside")
        )
        let repository = LocalArtifactRepository()
        let context = ArtifactCaptureContext(
            projectRoot: root,
            workspaceID: "workspace",
            sessionID: "session"
        )
        let first = try await repository.importFile(
            sourceURL: source,
            context: context,
            provenance: .created,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let record = try #require(first.record)
        let paths = ArtifactStorePaths(projectRoot: root)
        let metadataURL = paths.provenanceRoot.appendingPathComponent("\(record.digest).json")
        let corruptData = Data("{truncated".utf8)
        try corruptData.write(to: metadataURL)
        let filesBefore = try await repository.snapshot(projectRoot: root)
            .nodes
            .flattenedArtifactNodes()
            .filter { !$0.isDirectory }

        await #expect(throws: ArtifactStoreError.self) {
            try await repository.importFile(
                sourceURL: source,
                context: context,
                provenance: .created,
                configuration: .defaultValue,
                capturedAt: Date(timeIntervalSince1970: 2)
            )
        }

        let filesAfter = try await repository.snapshot(projectRoot: root)
            .nodes
            .flattenedArtifactNodes()
            .filter { !$0.isDirectory }
        #expect(filesAfter.map(\.relativePath) == filesBefore.map(\.relativePath))
        #expect(try Data(contentsOf: metadataURL) == corruptData)
    }

    @Test("Provenance rejects a symlinked cmux parent before writing")
    func rejectsSymlinkedCmuxParent() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let outside = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".cmux", isDirectory: true),
            withDestinationURL: outside
        )
        let paths = ArtifactStorePaths(projectRoot: root)

        #expect(throws: ArtifactStoreError.self) {
            try recorder.record(
                paths: paths,
                digest: "digest",
                relativePath: "workspace/session/plan.md",
                size: 4,
                event: event
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("Tree scans stream direct children within the node budget")
    func streamsBoundedDirectoryChildren() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let paths = ArtifactStorePaths(projectRoot: root)
        for index in 0..<20 {
            _ = try ArtifactTestSupport.write(
                "artifact \(index)",
                named: "artifact-\(index).txt",
                under: paths.artifactsRoot
            )
        }
        let fileManager = DirectoryEnumerationRecordingFileManager()
        let snapshot = try ArtifactTreeScanner(
            fileManager: fileManager,
            maximumDepth: 4,
            nodeBudget: 3
        ).snapshot(paths: paths)

        #expect(snapshot.nodes.count == 3)
        #expect(snapshot.isTruncated)
        #expect(fileManager.eagerDirectoryReadCount == 0)
    }

    @Test("Capture reports store-confinement failures distinctly")
    func reportsStoreConfinementFailure() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let outside = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(outside) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".cmux", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".cmux/artifacts", isDirectory: true),
            withDestinationURL: outside
        )
        let source = try ArtifactTestSupport.write("safe", named: "safe.md", under: root)

        let outcomes = await ArtifactCaptureService(store: LocalArtifactRepository()).capture(
            candidates: [ArtifactCandidate(sourceURL: source, provenance: .created)],
            context: ArtifactCaptureContext(projectRoot: root)
        )

        guard case .skipped(let reason) = outcomes.first else {
            Issue.record("Expected the unsafe store to reject capture")
            return
        }
        #expect(reason.rawValue == "pathOutsideStore")
    }

    @Test("Git exclude paths follow canonical project aliases")
    func ignoresCanonicalProjectAlias() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let project = root.appendingPathComponent("nested/project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("project-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)

        _ = try await LocalArtifactRepository().snapshot(projectRoot: alias)

        let exclude = try String(
            contentsOf: root.appendingPathComponent(".git/info/exclude"),
            encoding: .utf8
        )
        #expect(exclude == "nested/project/.cmux/artifacts/\n")
    }

    @Test("Git excludes artifact stores in paths containing pattern metacharacters")
    func escapesGitIgnorePatternCharacters() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        try runGit(["init", "--quiet", root.path])
        let project = root.appendingPathComponent("nested[1]/project?", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await LocalArtifactRepository().snapshot(projectRoot: project)
        let artifact = try ArtifactTestSupport.write(
            "private",
            named: "plan.md",
            under: project.appendingPathComponent(".cmux/artifacts")
        )
        let relativePath = try #require(
            ArtifactPathResolver().relativePath(artifact, root: root)
        )

        #expect(try runGit(["-C", root.path, "check-ignore", "--quiet", "--", relativePath]) == 0)
    }

    @Test("Unreadable Git exclude content is preserved")
    func preservesNonUTF8GitExcludeContent() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let info = root.appendingPathComponent(".git/info", isDirectory: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let exclude = info.appendingPathComponent("exclude", isDirectory: false)
        let existing = Data([0xFF, 0xFE, 0x0A])
        try existing.write(to: exclude)

        await #expect(throws: (any Error).self) {
            _ = try await LocalArtifactRepository().snapshot(projectRoot: root)
        }
        #expect(try Data(contentsOf: exclude) == existing)
    }

    @MainActor
    @Test("A canceled deduplication scan stops before visiting files")
    func cancelsDeduplicationScan() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let paths = ArtifactStorePaths(projectRoot: root)
        _ = try ArtifactTestSupport.write("same", named: "one.txt", under: paths.artifactsRoot)
        let scanTask = Task {
            var visits = 0
            try ArtifactDeduplicationScanner(fileManager: .default).scanFiles(
                paths: paths,
                matchingSizes: [4]
            ) { _, _ in
                visits += 1
                return false
            }
            return visits
        }
        scanTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await scanTask.value
        }
    }

    private var recorder: ArtifactProvenanceRecorder {
        ArtifactProvenanceRecorder(
            fileManager: .default,
            encoder: JSONEncoder(),
            decoder: JSONDecoder()
        )
    }

    private var event: ArtifactProvenanceEvent {
        ArtifactProvenanceEvent(
            sourcePath: "/tmp/plan.md",
            workspaceID: "workspace",
            sessionID: "session",
            provenance: .created,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
