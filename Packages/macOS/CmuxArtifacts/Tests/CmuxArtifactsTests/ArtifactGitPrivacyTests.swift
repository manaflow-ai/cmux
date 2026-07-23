import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact Git privacy")
struct ArtifactGitPrivacyTests {
    @Test("Automatic capture stops when a higher-priority ignore negation exposes artifacts")
    func rejectsNegatedArtifactIgnore() async throws {
        let root = try gitRepository()
        defer { ArtifactTestSupport.remove(root) }
        try "!/.cmux/\n!/.cmux/**/\n!/.cmux/**/artifacts/**\n".write(
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
            under: root.appendingPathComponent(".cmux/session/artifacts")
        )
        #expect(try runGit([
            "-C", root.path, "add", "--force", ".cmux/session/artifacts/tracked.md",
        ]) == 0)
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
        let context = ArtifactCaptureContext(
            projectRoot: root,
            workspaceID: "workspace",
            sessionID: "session"
        )
        let resolver = ArtifactPathResolver()
        let artifactDirectory = resolver.contentDirectory(
            paths: ArtifactStorePaths(projectRoot: root),
            context: context,
            kind: .artifacts
        )
        let artifactRelativePath = try #require(
            resolver.relativePath(artifactDirectory, root: root)
        )
        let sessionRelativePath = try #require(
            resolver.relativePath(artifactDirectory.deletingLastPathComponent(), root: root)
        )
        try """
        !/.cmux/
        !/\(sessionRelativePath)/
        !/\(artifactRelativePath)/
        /\(artifactRelativePath)/**
        !/\(artifactRelativePath)/*.json

        """.write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        #expect(try runGit([
            "-C", root.path, "check-ignore", "--quiet", "--",
            ".cmux/.metadata/imports/.__cmux_probe__",
        ]) == 0)
        #expect(try runGit([
            "-C", root.path, "check-ignore", "--quiet", "--",
            "\(artifactRelativePath)/secret.json",
        ]) == 1)
        let source = try ArtifactTestSupport.write(
            "secret",
            named: "outside/secret.json",
            under: root
        )

        let outcomes = await ArtifactCaptureService(store: repository).capture(
            candidates: [ArtifactCandidate(sourceURL: source, provenance: .created)],
            context: context
        )

        #expect(outcomes.first == .skipped(.gitPrivacyUnavailable))
        let files = try await repository.snapshot(projectRoot: root)
            .nodes
            .flattenedArtifactNodes()
            .filter { !$0.isDirectory }
        #expect(files.isEmpty)
    }

    @Test("Manual capture stops when an exact artifact destination is Git-visible")
    func rejectsExposedManualDestination() async throws {
        let root = try gitRepository()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        _ = try await repository.snapshot(projectRoot: root)
        let context = ArtifactCaptureContext(
            projectRoot: root,
            sessionID: "session:manual-privacy",
            agentName: "codex"
        )
        let resolver = ArtifactPathResolver()
        let artifactDirectory = resolver.contentDirectory(
            paths: ArtifactStorePaths(projectRoot: root),
            context: context,
            kind: .artifacts
        )
        let artifactRelativePath = try #require(
            resolver.relativePath(artifactDirectory, root: root)
        )
        let sessionRelativePath = try #require(
            resolver.relativePath(artifactDirectory.deletingLastPathComponent(), root: root)
        )
        let destinationRelativePath = "\(artifactRelativePath)/private.md"
        try """
        !/.cmux/
        !/\(sessionRelativePath)/
        !/\(artifactRelativePath)/
        /\(artifactRelativePath)/**
        !/\(artifactRelativePath)/*.md

        """.write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        #expect(try runGit([
            "-C", root.path, "check-ignore", "--quiet", "--", destinationRelativePath,
        ]) == 1)
        let source = try ArtifactTestSupport.write(
            "private",
            named: "outside/private.md",
            under: root
        )

        await #expect(throws: ArtifactStoreError.gitPrivacyUnavailable(
            ArtifactStorePaths(projectRoot: root).filesystemRoot.path
        )) {
            _ = try await repository.importFile(
                sourceURL: source,
                context: context,
                provenance: .manual,
                configuration: .defaultValue,
                capturedAt: Date(timeIntervalSince1970: 1)
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(destinationRelativePath).path
        ))
    }

    @Test("Note writes stop when an exact Markdown destination is Git-visible")
    func rejectsExposedNoteDestination() async throws {
        let root = try gitRepository()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        _ = try await repository.snapshot(projectRoot: root)
        let context = ArtifactCaptureContext(
            projectRoot: root,
            sessionID: "session:note-privacy",
            agentName: "codex"
        )
        let resolver = ArtifactPathResolver()
        let notesDirectory = resolver.contentDirectory(
            paths: ArtifactStorePaths(projectRoot: root),
            context: context,
            kind: .notes
        )
        let notesRelativePath = try #require(
            resolver.relativePath(notesDirectory, root: root)
        )
        let sessionRelativePath = try #require(
            resolver.relativePath(notesDirectory.deletingLastPathComponent(), root: root)
        )
        let destinationRelativePath = "\(notesRelativePath)/plan.md"
        try """
        !/.cmux/
        !/\(sessionRelativePath)/
        !/\(notesRelativePath)/
        /\(notesRelativePath)/**
        !/\(notesRelativePath)/*.md

        """.write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        #expect(try runGit([
            "-C", root.path, "check-ignore", "--quiet", "--", destinationRelativePath,
        ]) == 1)

        await #expect(throws: ArtifactStoreError.gitPrivacyUnavailable(
            ArtifactStorePaths(projectRoot: root).filesystemRoot.path
        )) {
            _ = try await repository.writeNote(
                name: "plan",
                text: "private",
                mode: .replace,
                context: context
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(destinationRelativePath).path
        ))
    }

    @Test("Note writes never overwrite tracked local-store content")
    func rejectsTrackedNoteDestination() async throws {
        let root = try gitRepository()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        _ = try await repository.snapshot(projectRoot: root)
        let context = ArtifactCaptureContext(
            projectRoot: root,
            sessionID: "session:tracked-note",
            agentName: "codex"
        )
        let notesDirectory = ArtifactPathResolver().contentDirectory(
            paths: ArtifactStorePaths(projectRoot: root),
            context: context,
            kind: .notes
        )
        let trackedNote = try ArtifactTestSupport.write(
            "tracked original",
            named: "plan.md",
            under: notesDirectory
        )
        let relativePath = try #require(
            ArtifactPathResolver().relativePath(trackedNote, root: root)
        )
        #expect(try runGit([
            "-C", root.path, "add", "--force", relativePath,
        ]) == 0)

        await #expect(throws: ArtifactStoreError.gitPrivacyUnavailable(
            ArtifactStorePaths(projectRoot: root).filesystemRoot.path
        )) {
            _ = try await repository.writeNote(
                name: "plan",
                text: "replacement",
                mode: .replace,
                context: context
            )
        }
        #expect(try String(contentsOf: trackedNote, encoding: .utf8) == "tracked original")
    }

    @Test("Reorganized project files stay ignored while root configuration stays trackable")
    func ignoresReorganizedFilesButNotConfiguration() async throws {
        let root = try gitRepository()
        defer { ArtifactTestSupport.remove(root) }
        _ = try await LocalArtifactRepository().snapshot(projectRoot: root)
        _ = try ArtifactTestSupport.write(
            "private",
            named: "organized/final.txt",
            under: root.appendingPathComponent(".cmux")
        )
        _ = try ArtifactTestSupport.write(
            #"{"automaticCaptureEnabled":false}"#,
            named: "artifacts.json",
            under: root.appendingPathComponent(".cmux")
        )

        #expect(try runGit([
            "-C", root.path, "check-ignore", "--quiet", "--",
            ".cmux/organized/final.txt",
        ]) == 0)
        #expect(try runGit([
            "-C", root.path, "check-ignore", "--quiet", "--",
            ".cmux/artifacts.json",
        ]) == 1)
    }

    @Test("Tracked reorganized content blocks later automatic capture")
    func rejectsTrackedReorganizedStoreContent() async throws {
        let root = try gitRepository()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        _ = try await repository.snapshot(projectRoot: root)
        _ = try ArtifactTestSupport.write(
            "tracked",
            named: "organized/final.txt",
            under: root.appendingPathComponent(".cmux")
        )
        #expect(try runGit([
            "-C", root.path, "add", "--force", ".cmux/organized/final.txt",
        ]) == 0)
        let source = try ArtifactTestSupport.write(
            "new private output",
            named: "outside/new.md",
            under: root
        )

        let outcomes = await ArtifactCaptureService(store: repository).capture(
            candidates: [ArtifactCandidate(sourceURL: source, provenance: .created)],
            context: ArtifactCaptureContext(projectRoot: root)
        )

        #expect(outcomes.first == .skipped(.gitPrivacyUnavailable))
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
