import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact Git privacy")
struct ArtifactGitPrivacyTests {
    @Test("Automatic capture stops when a higher-priority ignore negation exposes artifacts")
    func rejectsNegatedArtifactIgnore() async throws {
        let root = try gitRepository()
        defer { ArtifactTestSupport.remove(root) }
        try "!/.cmux/artifacts/\n!/.cmux/artifacts/**\n".write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let source = try ArtifactTestSupport.write(
            "secret",
            named: "outside/secret.md",
            under: root
        )

        let outcomes = await ArtifactCaptureService(store: LocalArtifactRepository()).capture(
            candidates: [ArtifactCandidate(sourceURL: source, provenance: .created)],
            context: ArtifactCaptureContext(projectRoot: root)
        )

        #expect(outcomes.first?.record == nil)
    }

    @Test("Automatic capture stops when the artifact store already contains tracked files")
    func rejectsTrackedArtifactStore() async throws {
        let root = try gitRepository()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        _ = try await repository.snapshot(projectRoot: root)
        _ = try ArtifactTestSupport.write(
            "tracked",
            named: "tracked.md",
            under: root.appendingPathComponent(".cmux/artifacts")
        )
        #expect(try runGit(["-C", root.path, "add", "--force", ".cmux/artifacts/tracked.md"]) == 0)
        let source = try ArtifactTestSupport.write(
            "new secret",
            named: "outside/new-secret.md",
            under: root
        )

        let outcomes = await ArtifactCaptureService(store: repository).capture(
            candidates: [ArtifactCandidate(sourceURL: source, provenance: .created)],
            context: ArtifactCaptureContext(projectRoot: root)
        )

        #expect(outcomes.first?.record == nil)
    }

    @Test("Automatic capture checks extension-specific ignore rules at its real destination")
    func rejectsExposedJSONDestinationWhenSyntheticProbeIsIgnored() async throws {
        let root = try gitRepository()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        _ = try await repository.snapshot(projectRoot: root)
        try """
        !/.cmux/
        !/.cmux/artifacts/
        /.cmux/artifacts/**
        !/.cmux/artifacts/workspace-workspace/
        !/.cmux/artifacts/workspace-workspace/session-session/
        !/.cmux/artifacts/**/*.json

        """.write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        #expect(try runGit([
            "-C", root.path, "check-ignore", "--quiet", "--",
            ".cmux/artifacts/.__cmux_probe__",
        ]) == 0)
        #expect(try runGit([
            "-C", root.path, "check-ignore", "--quiet", "--",
            ".cmux/artifacts/workspace-workspace/session-session/secret.json",
        ]) == 1)
        let source = try ArtifactTestSupport.write(
            "secret",
            named: "outside/secret.json",
            under: root
        )

        let outcomes = await ArtifactCaptureService(store: repository).capture(
            candidates: [ArtifactCandidate(sourceURL: source, provenance: .created)],
            context: ArtifactCaptureContext(
                projectRoot: root,
                workspaceID: "workspace",
                sessionID: "session"
            )
        )

        #expect(outcomes.first == .skipped(.gitPrivacyUnavailable))
        let files = try await repository.snapshot(projectRoot: root)
            .nodes
            .flattenedArtifactNodes()
            .filter { !$0.isDirectory }
        #expect(files.isEmpty)
    }

    private func gitRepository() throws -> URL {
        let root = try ArtifactTestSupport.temporaryDirectory()
        #expect(try runGit(["init", "--quiet", root.path]) == 0)
        return root
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
