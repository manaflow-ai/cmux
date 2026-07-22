import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact capture service")
struct ArtifactCaptureServiceTests {
    @Test("Automatic references cannot expand access beyond the project")
    func restrictsReferencedPathsToProject() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let temporary = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(temporary) }
        let projectLocal = try ArtifactTestSupport.write("keep", named: "project.md", under: root)
        let external = try ArtifactTestSupport.write("private", named: "external.md", under: temporary)
        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.ephemeralPathPrefixes = [temporary.path]
        let store = ConfiguredArtifactStore(configuration: configuration)
        let service = ArtifactCaptureService(store: store)
        let context = ArtifactCaptureContext(projectRoot: root)

        let outcomes = await service.capture(
            candidates: [
                ArtifactCandidate(sourceURL: projectLocal, provenance: .referenced),
                ArtifactCandidate(sourceURL: external, provenance: .referenced),
            ],
            context: context
        )

        #expect(outcomes.first?.record?.sourcePath == projectLocal.path)
        #expect(outcomes.last == .skipped(.provenanceNotEligible))
        #expect(await store.importCount == 1)
    }

    @Test("Project configuration can narrow but not expand trusted ephemeral roots")
    func clampsEphemeralPrefixes() {
        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.ephemeralPathPrefixes = [
            "/",
            "/tmp/cmux-session",
            "/private/tmp/cmux-session",
            "/var/folders/zz",
            "/Users/shared",
        ]

        let prefixes = configuration.normalized.ephemeralPathPrefixes
        #expect(!prefixes.contains("/"))
        #expect(!prefixes.contains("/Users/shared"))
        #expect(prefixes.contains { $0.hasSuffix("/tmp/cmux-session") })
        #expect(prefixes.contains("/var/folders/zz"))
    }

    @Test("Candidate limits are enforced before imports")
    func enforcesCandidateLimit() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let first = try ArtifactTestSupport.write("one", named: "one.md", under: root)
        let second = try ArtifactTestSupport.write("two", named: "two.md", under: root)
        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.maximumFilesPerCapture = 1
        let store = ConfiguredArtifactStore(configuration: configuration)
        let outcomes = await ArtifactCaptureService(store: store).capture(
            candidates: [
                ArtifactCandidate(sourceURL: first, provenance: .created),
                ArtifactCandidate(sourceURL: second, provenance: .created),
            ],
            context: ArtifactCaptureContext(projectRoot: root)
        )
        #expect(outcomes.count == 2)
        #expect(outcomes.last == .skipped(.candidateLimitReached))
        #expect(await store.importCount == 1)
    }

    @Test("Manual selections share configuration and use bounded persistence batches")
    func batchesManualSelection() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.maximumFilesPerCapture = 2
        let store = ConfiguredArtifactStore(configuration: configuration)
        let sources = (0..<5).map { root.appendingPathComponent("artifact-\($0).md") }

        let attempts = await ArtifactCaptureService(store: store).add(
            sourceURLs: sources,
            context: ArtifactCaptureContext(projectRoot: root)
        )

        #expect(attempts.count == sources.count)
        #expect(await store.configurationReadCount == 1)
        #expect(await store.batchImportCount == 3)
        #expect(await store.importCount == sources.count)
    }

    @Test("Ephemeral prefixes match canonical macOS path aliases")
    func matchesCanonicalTemporaryAlias() throws {
        let temporary = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(temporary) }
        let alternatePath = temporary.path.hasPrefix("/private/")
            ? String(temporary.path.dropFirst("/private".count))
            : "/private\(temporary.path)"
        let privateAlias = URL(
            fileURLWithPath: alternatePath,
            isDirectory: true
        )

        let isEphemeral = ArtifactPathResolver().isEphemeral(
            privateAlias.appendingPathComponent("preview.md"),
            prefixes: [temporary.path],
            temporaryDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        #expect(isEphemeral)
    }
}
