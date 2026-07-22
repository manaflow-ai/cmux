import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact Git exclude safety")
struct ArtifactGitIgnoreSafetyTests {
    @Test("A symlinked Git info directory cannot redirect exclude writes")
    func rejectsSymlinkedInfoDirectory() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let outside = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(outside) }
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        let outsideExclude = try ArtifactTestSupport.write(
            "preserve\n",
            named: "exclude",
            under: outside
        )
        try FileManager.default.createSymbolicLink(
            at: gitDirectory.appendingPathComponent("info", isDirectory: true),
            withDestinationURL: outside
        )

        await #expect(throws: (any Error).self) {
            _ = try await LocalArtifactRepository().snapshot(projectRoot: root)
        }

        #expect(try String(contentsOf: outsideExclude, encoding: .utf8) == "preserve\n")
    }

    @Test("A symlinked Git exclude file cannot redirect writes")
    func rejectsSymlinkedExcludeFile() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let outside = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(outside) }
        let infoDirectory = root.appendingPathComponent(".git/info", isDirectory: true)
        try FileManager.default.createDirectory(at: infoDirectory, withIntermediateDirectories: true)
        let outsideExclude = try ArtifactTestSupport.write(
            "preserve\n",
            named: "outside-exclude",
            under: outside
        )
        try FileManager.default.createSymbolicLink(
            at: infoDirectory.appendingPathComponent("exclude", isDirectory: false),
            withDestinationURL: outsideExclude
        )

        await #expect(throws: (any Error).self) {
            _ = try await LocalArtifactRepository().snapshot(projectRoot: root)
        }

        #expect(try String(contentsOf: outsideExclude, encoding: .utf8) == "preserve\n")
    }
}
