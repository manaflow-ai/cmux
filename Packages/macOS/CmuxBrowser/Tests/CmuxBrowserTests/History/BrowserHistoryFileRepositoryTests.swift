import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserHistoryFileRepositoryTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserHistoryFileRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func entry(_ url: String) -> BrowserHistoryEntry {
        BrowserHistoryEntry(id: UUID(), url: url, title: nil, lastVisited: Date(timeIntervalSince1970: 5), visitCount: 1)
    }

    @Test func persistThenLoadRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("browser_history.json")
        let repo = BrowserHistoryFileRepository()
        let snapshot = [entry("https://a.example/"), entry("https://b.example/")]

        try BrowserHistoryFileRepository.persist(snapshot, to: fileURL)
        let loaded = repo.loadSnapshot(from: fileURL)
        #expect(loaded == snapshot)
    }

    @Test func persistUsesUnescapedSlashes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("browser_history.json")
        try BrowserHistoryFileRepository.persist([entry("https://x.example/p")], to: fileURL)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(text.contains("https://x.example/p"))
        #expect(!text.contains("https:\\/\\/"))
    }

    @Test func loadMissingFileReturnsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = BrowserHistoryFileRepository()
        #expect(repo.loadSnapshot(from: dir.appendingPathComponent("absent.json")) == nil)
    }

    @Test func removeFileDeletesSnapshot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("browser_history.json")
        try BrowserHistoryFileRepository.persist([entry("https://a.example/")], to: fileURL)
        let repo = BrowserHistoryFileRepository()
        repo.removeFile(at: fileURL)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func migrateCopiesLegacyFileOnlyWhenTargetAbsent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("legacy/browser_history.json")
        let targetURL = dir.appendingPathComponent("current/browser_history.json")
        try BrowserHistoryFileRepository.persist([entry("https://legacy.example/")], to: legacyURL)

        let repo = BrowserHistoryFileRepository()
        repo.migrateLegacyFileIfNeeded(legacyURL: legacyURL, to: targetURL)
        #expect(repo.loadSnapshot(from: targetURL)?.first?.url == "https://legacy.example/")

        // A second migration must not clobber the now-present target.
        try BrowserHistoryFileRepository.persist([entry("https://current.example/")], to: targetURL)
        repo.migrateLegacyFileIfNeeded(legacyURL: legacyURL, to: targetURL)
        #expect(repo.loadSnapshot(from: targetURL)?.first?.url == "https://current.example/")
    }
}
