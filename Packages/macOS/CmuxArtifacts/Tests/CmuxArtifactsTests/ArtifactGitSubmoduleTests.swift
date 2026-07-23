import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact Git submodule privacy")
struct ArtifactGitSubmoduleTests {
    @Test("Manual artifact setup writes the submodule-local exclude")
    func manualSetupIgnoresArtifactsInSubmodules() async throws {
        let fixture = try makeFixture()
        defer { ArtifactTestSupport.remove(fixture.root) }

        _ = try await LocalArtifactRepository().snapshot(projectRoot: fixture.submodule)

        let exclude = fixture.gitDirectory.appendingPathComponent("info/exclude", isDirectory: false)
        let contents = try String(contentsOf: exclude, encoding: .utf8)
        let lines = Set(contents.split(separator: "\n").map(String.init))
        #expect(lines.isSuperset(of: Set(ArtifactGitIgnoreManager.ignoreEntries)))
    }

    @Test("Automatic imports remain private inside submodules")
    func automaticCaptureUsesTheSubmoduleExclude() async throws {
        let fixture = try makeFixture()
        defer { ArtifactTestSupport.remove(fixture.root) }
        let source = try ArtifactTestSupport.write(
            "private plan",
            named: "outside/plan.md",
            under: fixture.root
        )
        let outcomes = await ArtifactCaptureService(store: LocalArtifactRepository()).capture(
            candidates: [ArtifactCandidate(sourceURL: source, provenance: .created)],
            context: ArtifactCaptureContext(projectRoot: fixture.submodule)
        )

        let record = try #require(outcomes.first?.record)
        #expect(try ArtifactTestSupport.runGit([
            "-C", fixture.submodule.path,
            "check-ignore", "--quiet", "--",
            ".cmux/\(record.relativePath)",
        ]) == 0)
    }

    private func makeFixture() throws -> (root: URL, submodule: URL, gitDirectory: URL) {
        let root = try ArtifactTestSupport.temporaryDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        let superproject = root.appendingPathComponent("super", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: superproject, withIntermediateDirectories: true)
        #expect(try ArtifactTestSupport.runGit(["init", "--quiet", source.path]) == 0)
        _ = try ArtifactTestSupport.write("seed", named: "README.md", under: source)
        #expect(try ArtifactTestSupport.runGit(["-C", source.path, "add", "README.md"]) == 0)
        #expect(try ArtifactTestSupport.runGit([
            "-C", source.path,
            "-c", "user.name=cmux tests",
            "-c", "user.email=cmux@example.invalid",
            "commit", "--quiet", "-m", "seed",
        ]) == 0)
        #expect(try ArtifactTestSupport.runGit(["init", "--quiet", superproject.path]) == 0)
        #expect(try ArtifactTestSupport.runGit([
            "-c", "protocol.file.allow=always",
            "-C", superproject.path,
            "submodule", "add", "--quiet", source.path, "child",
        ]) == 0)
        let submodule = superproject.appendingPathComponent("child", isDirectory: true)
        let marker = try String(
            contentsOf: submodule.appendingPathComponent(".git", isDirectory: false),
            encoding: .utf8
        )
        let rawGitDirectory = marker.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDirectory = URL(
            fileURLWithPath: rawGitDirectory,
            relativeTo: submodule
        ).standardizedFileURL
        return (root, submodule, gitDirectory)
    }
}
