import Foundation
import Testing
@testable import CmuxArtifacts

/// Regression coverage for review findings on the persisted Artifacts
/// catalog: ignore-list port matching, legacy import bounds, payload cleanup
/// on scoped replacement, and identity stability across reloads.
@Suite("Local artifact repository review regressions")
struct LocalArtifactRepositoryReviewRegressionTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxArtifactsReviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func terminalURL(_ url: String, ownership: ArtifactOwnership) -> ArtifactIngestRequest {
        ArtifactIngestRequest(
            input: .url(url),
            ownership: ownership,
            source: .terminalURL,
            authorization: .automatic(allowedRoots: [])
        )
    }

    @Test("explicit ingest promotes a deduplicated automatic record to user-owned")
    func explicitIngestPromotesExistingRecord() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalArtifactRepository(rootURL: root, configuration: .init(retentionAge: 0))
        let ownership = ArtifactOwnership(workspaceID: "w")

        let automatic = try await repo.ingest(
            terminalURL("https://example.com/promote", ownership: ownership),
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        #expect(!automatic.isUserOwned)

        let explicit = try await repo.ingest(
            .init(
                input: .url("https://example.com/promote"),
                ownership: ownership,
                source: .manual,
                authorization: .explicitUser
            ),
            capturedAt: Date(timeIntervalSince1970: 20)
        )
        #expect(explicit.id == automatic.id)
        #expect(explicit.isUserOwned)
    }

    @Test("ignore-list entries match host:port, wildcard suffixes, and bracketed IPv6 keys")
    func ignoreListMatchesHostPortEntries() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalArtifactRepository(
            rootURL: root,
            configuration: .init(
                ignoreHosts: ["localhost:31034", "[::1]:8080", "*.internal.example", "ci.example"],
                retentionAge: 0
            )
        )
        let owner = ArtifactOwnership(workspaceID: "w")

        let ignored = [
            "http://localhost:31034/preview",
            "http://LOCALHOST.:31034/status",
            "http://[::1]:8080/index.html",
            "https://api.internal.example/v1",
            "http://ci.example:9000/build",
        ]
        for url in ignored {
            await #expect(
                throws: ArtifactStoreError.unsupportedKind("ignored or invalid host"),
                Comment(rawValue: url)
            ) {
                _ = try await repo.ingest(terminalURL(url, ownership: owner), capturedAt: .now)
            }
        }

        // Same hosts on other ports, longer host names, and unrelated suffixes
        // must still be captured; the ignore list is exact per entry.
        let captured = [
            "http://localhost:3000/app",
            "http://[::1]:8081/index.html",
            "http://ci.example.com/build",
            "https://internal.example.org/",
        ]
        for url in captured {
            _ = try await repo.ingest(terminalURL(url, ownership: owner), capturedAt: .now)
        }
        #expect(try await repo.list(scope: .workspace("w")).count == captured.count)
    }

    @Test("legacy Links migration keeps every row instead of the producer batch cap")
    func legacyImportIsNotBoundedByBatchCap() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = ArtifactOwnership(workspaceID: "w")
        let links = (0..<200).map { index in
            ArtifactLegacyLink(
                id: UUID(),
                url: "https://example.com/link-\(index)",
                firstSeen: Date(timeIntervalSince1970: Double(index)),
                lastSeen: Date(timeIntervalSince1970: Double(index)),
                count: 1,
                origin: "detected",
                sourcePanelID: nil,
                sourceSurfaceTitle: nil,
                fetchedTitle: nil
            )
        }
        let repo = LocalArtifactRepository(
            rootURL: root,
            configuration: .init(retentionLimit: 500, retentionAge: 0, maximumBatchCount: 64)
        )
        let imported = try await repo.importLegacyLinks(links, ownership: owner)
        #expect(imported.count == links.count)
        #expect(try await repo.list(scope: .workspace("w")).count == links.count)

        // Per-workspace retention still bounds the migrated history.
        let boundedRoot = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: boundedRoot) }
        let bounded = LocalArtifactRepository(
            rootURL: boundedRoot,
            configuration: .init(retentionLimit: 10, retentionAge: 0, maximumBatchCount: 64)
        )
        _ = try await bounded.importLegacyLinks(links, ownership: owner)
        let retained = try await bounded.list(scope: .workspace("w"))
        #expect(retained.count == 10)
        #expect(retained.first?.representation == .url("https://example.com/link-199"))
    }

    @Test("scoped replacement removes managed payloads that no record references")
    func replaceRemovesUnreferencedPayloads() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalArtifactRepository(rootURL: root, configuration: .init(retentionAge: 0))
        let owner = ArtifactOwnership(workspaceID: "w")
        let other = ArtifactOwnership(workspaceID: "other")
        let bytes = Data("shared payload".utf8)
        let record = try await repo.ingest(
            .init(input: .data(bytes, fileName: "note.txt", mimeType: "text/plain"), ownership: owner, source: .manual),
            capturedAt: .now
        )
        let shared = try await repo.ingest(
            .init(input: .data(bytes, fileName: "note.txt", mimeType: "text/plain"), ownership: other, source: .manual),
            capturedAt: .now
        )
        let materialized = try await repo.materializedURL(for: record)
        let payloadURL = try #require(materialized)
        #expect(shared.representation.managedRelativePath == record.representation.managedRelativePath)
        #expect(FileManager.default.fileExists(atPath: payloadURL.path))

        // The other workspace still references the same content-addressed payload.
        try await repo.replace(records: [], scope: .workspace("w"))
        #expect(try await repo.list(scope: .workspace("w")).isEmpty)
        #expect(FileManager.default.fileExists(atPath: payloadURL.path))

        // A replacement that keeps the record keeps its payload.
        try await repo.replace(records: [shared], scope: .workspace("other"))
        #expect(try await repo.list(scope: .workspace("other")).count == 1)
        #expect(FileManager.default.fileExists(atPath: payloadURL.path))

        // Dropping the last referencing record deletes the payload file.
        try await repo.replace(records: [], scope: .workspace("other"))
        #expect(try await repo.list(scope: .global).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
    }

    @Test("URL identity survives a reload when only the project root is known")
    func urlIdentityIsStableAcrossReloadWithDerivedProject() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // No explicit project id: the repository derives one from the root.
        let owner = ArtifactOwnership(workspaceID: "w", projectRoot: root.path)
        let first = LocalArtifactRepository(rootURL: root, configuration: .init(retentionAge: 0))
        let original = try await first.ingest(
            terminalURL("https://example.com/report", ownership: owner),
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        let projectID = try #require(original.ownership.projectID)

        let reloaded = LocalArtifactRepository(rootURL: root, configuration: .init(retentionAge: 0))
        let again = try await reloaded.ingest(
            terminalURL("https://example.com/report", ownership: owner),
            capturedAt: Date(timeIntervalSince1970: 20)
        )
        #expect(again.id == original.id)
        #expect(again.occurrenceCount == 2)
        #expect(again.identityKey == original.identityKey)
        #expect(try await reloaded.list(scope: .workspace("w")).count == 1)
        #expect(try await reloaded.list(scope: .project(projectID)).count == 1)
    }
}
