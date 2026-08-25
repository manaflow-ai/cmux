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
        configuration.ephemeralPathPrefixes = [root.path, temporary.path]
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

    @Test("Referenced capture rejects symlinked prefixes outside trusted roots")
    func rejectsSymlinkedEphemeralPrefixOutsideTrustedRoots() async throws {
        let projectRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("CmuxArtifactsTests-\(UUID().uuidString)", isDirectory: true)
        defer { ArtifactTestSupport.remove(projectRoot) }
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let source = try ArtifactTestSupport.write("private", named: "project.md", under: projectRoot)

        let alias = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxArtifactsPrefix-\(UUID().uuidString)", isDirectory: true)
        defer { ArtifactTestSupport.remove(alias) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: projectRoot)

        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.ephemeralPathPrefixes = [alias.path]
        let store = ConfiguredArtifactStore(configuration: configuration)
        let outcomes = await ArtifactCaptureService(store: store).capture(
            candidates: [ArtifactCandidate(sourceURL: source, provenance: .referenced)],
            context: ArtifactCaptureContext(projectRoot: projectRoot)
        )

        #expect(outcomes.first == .skipped(.provenanceNotEligible))
        #expect(await store.importCount == 0)
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

    @Test("Automatic capture enforces its aggregate staged-byte budget")
    func enforcesAggregateAutomaticCaptureByteLimit() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        #expect(try ArtifactTestSupport.runGit(["init", "--quiet", root.path]) == 0)
        _ = try ArtifactTestSupport.write(
            """
            {
              "maximumFileBytes": 10,
              "maximumTextFileBytes": 10,
              "maximumAutomaticCaptureBytes": 6
            }
            """,
            named: ".cmux/artifacts.json",
            under: root
        )
        let first = try ArtifactTestSupport.write("1111", named: "outside/first.md", under: root)
        let second = try ArtifactTestSupport.write("2222", named: "outside/second.md", under: root)

        let outcomes = await ArtifactCaptureService(store: LocalArtifactRepository()).capture(
            candidates: [
                ArtifactCandidate(sourceURL: first, provenance: .created),
                ArtifactCandidate(sourceURL: second, provenance: .created),
            ],
            context: ArtifactCaptureContext(projectRoot: root)
        )

        #expect(outcomes.first?.record != nil)
        #expect(outcomes.last == .skipped(.candidateLimitReached))
    }

    @Test("An oversized first candidate does not starve smaller later candidates")
    func oversizedFirstCandidateDoesNotStarveBatch() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        #expect(try ArtifactTestSupport.runGit(["init", "--quiet", root.path]) == 0)
        _ = try ArtifactTestSupport.write(
            """
            {
              "maximumFileBytes": 10,
              "maximumTextFileBytes": 10,
              "maximumAutomaticCaptureBytes": 6
            }
            """,
            named: ".cmux/artifacts.json",
            under: root
        )
        let oversized = try ArtifactTestSupport.write(
            "12345678",
            named: "outside/oversized.md",
            under: root
        )
        let accepted = try ArtifactTestSupport.write(
            "1234",
            named: "outside/accepted.md",
            under: root
        )

        let outcomes = await ArtifactCaptureService(store: LocalArtifactRepository()).capture(
            candidates: [
                ArtifactCandidate(sourceURL: oversized, provenance: .created),
                ArtifactCandidate(sourceURL: accepted, provenance: .created),
            ],
            context: ArtifactCaptureContext(projectRoot: root)
        )

        #expect(outcomes.first == .skipped(.exceedsSizeLimit))
        #expect(outcomes.last?.record?.sourcePath == accepted.path)
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

    @Test("Explicit saves reject a parent swap after authorization")
    func rejectsAuthorizedPathParentSwap() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let authorizedParent = root.appendingPathComponent("authorized", isDirectory: true)
        let outside = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(outside) }
        try FileManager.default.createDirectory(at: authorizedParent, withIntermediateDirectories: true)
        let source = authorizedParent.appendingPathComponent("plan.md")
        try "authorized".write(to: source, atomically: true, encoding: .utf8)
        let expectedCanonicalPath = source.resolvingSymlinksInPath().standardizedFileURL.path
        try "outside".write(
            to: outside.appendingPathComponent("plan.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.removeItem(at: authorizedParent)
        try FileManager.default.createSymbolicLink(at: authorizedParent, withDestinationURL: outside)

        await #expect(throws: ArtifactStoreError.self) {
            _ = try await ArtifactCaptureService(store: LocalArtifactRepository()).add(
                sourceURL: source,
                context: ArtifactCaptureContext(projectRoot: root),
                expectedCanonicalPath: expectedCanonicalPath
            )
        }
    }

    @Test("Manual selections continue across aggregate byte-bounded batches")
    func boundsManualSelectionBatchBytes() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.maximumFileBytes = 8
        configuration.maximumTextFileBytes = 4
        configuration.maximumFilesPerCapture = 3
        let store = ConfiguredArtifactStore(
            configuration: configuration,
            limitsAggregateBatchToFirstCandidate: true
        )
        let sources = (0..<3).map { root.appendingPathComponent("artifact-\($0).md") }

        let attempts = await ArtifactCaptureService(store: store).add(
            sourceURLs: sources,
            context: ArtifactCaptureContext(projectRoot: root)
        )

        #expect(attempts.allSatisfy {
            if case .imported = $0 { return true }
            return false
        })
        #expect(await store.importCount == sources.count)
        #expect(await store.batchImportCount == sources.count)
        #expect(await store.receivedMaximumBatchBytes == [8, 8, 8])
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

        let isEphemeral = ArtifactPathResolver(fileManager: .default).isEphemeral(
            privateAlias.appendingPathComponent("preview.md"),
            prefixes: [temporary.path]
        )

        #expect(isEphemeral)
    }
}
