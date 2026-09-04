import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Local artifact repository")
struct LocalArtifactRepositoryTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxArtifactsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("URL records dedupe and survive a fresh repository")
    func urlDedupeAndPersistence() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = ArtifactOwnership(workspaceID: "workspace-1", projectRoot: root.path)
        let first = LocalArtifactRepository(rootURL: root)
        let one = try await first.ingest(.init(input: .url("https://Example.com:443/a"), ownership: owner, source: .terminalURL), capturedAt: .init(timeIntervalSince1970: 10))
        let two = try await first.ingest(.init(input: .url("https://example.com/a"), ownership: owner, source: .terminalOSC8), capturedAt: .init(timeIntervalSince1970: 20))
        #expect(one.id == two.id)
        #expect(two.occurrenceCount == 2)
        #expect(try await first.list(scope: .workspace("workspace-1")).count == 1)

        let reloaded = LocalArtifactRepository(rootURL: root)
        let restored = try await reloaded.list(scope: .global)
        #expect(restored.count == 1)
        #expect(restored[0].lastSeenAt == .init(timeIntervalSince1970: 20))
    }

    @Test("HTML, text, image data, and directory records use bounded representations")
    func supportedInputs() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = ArtifactOwnership(workspaceID: "w", projectRoot: root.path)
        let repo = LocalArtifactRepository(rootURL: root, configuration: .init(retentionAge: 0))
        _ = try await repo.ingest(.init(input: .html("<p>Hello</p>"), ownership: owner, source: .browser), capturedAt: .now)
        _ = try await repo.ingest(.init(input: .text("let value = 1"), kind: .code, ownership: owner, source: .generated), capturedAt: .now)
        _ = try await repo.ingest(.init(input: .data(Data([0, 1, 2]), fileName: "image.png", mimeType: "image/png"), ownership: owner, source: .manual), capturedAt: .now)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        _ = try await repo.ingest(.init(input: .directory(root.appendingPathComponent("folder")), ownership: owner, source: .manual), capturedAt: .now)
        let records = try await repo.list(scope: .workspace("w"))
        #expect(records.map(\.kind).contains(.html))
        #expect(records.map(\.kind).contains(.code))
        #expect(records.map(\.kind).contains(.image))
        #expect(records.map(\.kind).contains(.directory))
    }

    @Test("automatic file capture enforces containment and privacy")
    func automaticFileCaptureSafety() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.txt")
        try Data("hello".utf8).write(to: source)
        let repo = LocalArtifactRepository(rootURL: root)
        let owner = ArtifactOwnership(workspaceID: "w", projectRoot: root.path)
        let record = try await repo.ingest(
            .init(input: .file(source), ownership: owner, source: .terminalPath, authorization: .automatic(allowedRoots: [root.path])),
            capturedAt: .now
        )
        #expect(record.kind == .text)
        #expect(try await repo.materializedURL(for: record) != nil)

        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-secret.txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        await #expect(throws: ArtifactStoreError.self) {
            _ = try await repo.ingest(.init(input: .file(outside), ownership: owner, source: .terminalPath, authorization: .automatic(allowedRoots: [root.path])), capturedAt: .now)
        }
    }

    @Test("legacy Links rows migrate without duplicate identities")
    func legacyLinksMigrate() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalArtifactRepository(rootURL: root, configuration: .init(retentionAge: 0))
        let owner = ArtifactOwnership(workspaceID: "w", projectRoot: root.path)
        let link = ArtifactLegacyLink(id: UUID(), url: "https://example.com", firstSeen: .init(timeIntervalSince1970: 1), lastSeen: .init(timeIntervalSince1970: 2), count: 3, origin: "osc8", sourcePanelID: nil, sourceSurfaceTitle: "Terminal", fetchedTitle: "Example")
        let imported = try await repo.importLegacyLinks([link], ownership: owner)
        #expect(imported.count == 1)
        _ = try await repo.importLegacyLinks([link], ownership: owner)
        #expect(try await repo.list(scope: .global).count == 1)
    }

    @Test("changed file bytes create a new content identity")
    func fileRevisionsUseContentIdentity() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.txt")
        let owner = ArtifactOwnership(workspaceID: "w", projectRoot: root.path)
        try Data("one".utf8).write(to: source)
        let repo = LocalArtifactRepository(rootURL: root, configuration: .init(retentionAge: 0))
        let first = try await repo.ingest(.init(input: .file(source), ownership: owner, source: .generated), capturedAt: .now)
        try Data("two".utf8).write(to: source)
        let second = try await repo.ingest(.init(input: .file(source), ownership: owner, source: .generated), capturedAt: .now)
        #expect(first.id != second.id)
        #expect(try await repo.list(scope: .workspace("w")).count == 2)
    }
}
