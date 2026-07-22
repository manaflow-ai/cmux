import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact repository safety")
struct ArtifactRepositorySafetyTests {
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

        #expect(throws: DecodingError.self) {
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
}
