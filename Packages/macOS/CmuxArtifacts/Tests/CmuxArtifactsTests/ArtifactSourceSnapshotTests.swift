import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact source snapshots")
struct ArtifactSourceSnapshotTests {
    @Test("A staged source remains immutable when the original changes")
    func stagedSourceIsImmutable() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write("initial", named: "result.txt", under: root)
        let paths = ArtifactStorePaths(projectRoot: root)
        let lease = try ArtifactImportStagingLease.acquire(
            root: paths.importStagingRoot,
            fileManager: .default
        )
        defer { lease.finish() }
        let snapshot = try ArtifactSourceSnapshotter(fileManager: .default).snapshot(
            source: source,
            paths: paths,
            configuration: .defaultValue,
            stagedURL: lease.makeStagedURL()
        )

        try "changed after staging".write(to: source, atomically: true, encoding: .utf8)

        #expect(snapshot.size == 7)
        #expect(try String(contentsOf: snapshot.url, encoding: .utf8) == "initial")
    }
}
