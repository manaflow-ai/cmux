import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact capture service")
struct ArtifactCaptureServiceTests {
    @Test("Referenced paths are captured only from ephemeral storage")
    func filtersReferencedPathsByLocation() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let temporary = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(temporary) }
        let persistent = try ArtifactTestSupport.write("keep", named: "persistent.md", under: root)
        let ephemeral = try ArtifactTestSupport.write("save", named: "ephemeral.md", under: temporary)
        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.ephemeralPathPrefixes = [temporary.path]
        let store = ConfiguredArtifactStore(configuration: configuration)
        let service = ArtifactCaptureService(store: store, temporaryDirectory: temporary)
        let context = ArtifactCaptureContext(projectRoot: root)

        let outcomes = await service.capture(
            candidates: [
                ArtifactCandidate(sourceURL: persistent, provenance: .referenced),
                ArtifactCandidate(sourceURL: ephemeral, provenance: .referenced),
            ],
            context: context
        )

        #expect(outcomes.first == .skipped(.provenanceNotEligible))
        #expect(outcomes.last?.record?.sourcePath == ephemeral.path)
        #expect(await store.importCount == 1)
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
