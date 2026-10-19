@testable import CmuxNextApp
import Foundation
import Testing

@Suite(.serialized) struct BrowserDownloadHistoryPermissionsTests {
    @Test func persistedBrowserMetadataIsPrivate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-download-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("downloads.json")
        try Data(#"{"downloads":[]}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let history = BrowserDownloadHistory(url: file)
        _ = await history.load()
        #expect(try permissions(of: root) == 0o700)
        #expect(try permissions(of: file) == 0o600)

        history.record([BrowserDownloadHistory.Row(
            filename: "download.txt", source: "https://example.test/download", destination: "/Downloads/download.txt",
            status: "finished", reason: nil, received: 8, total: 8
        )])
        await history.waitForPendingWrites()
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try permissions(of: file) == 0o600)
        let rows = await history.load()
        #expect(rows.map(\.filename) == ["download.txt"])
    }

    @Test func newBrowserMetadataIsPrivate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-download-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("downloads.json")
        let history = BrowserDownloadHistory(url: file)
        history.record([BrowserDownloadHistory.Row(
            filename: "new-download.txt", source: "https://example.test/new", destination: nil,
            status: "finished", reason: nil, received: 3, total: 3
        )])
        await history.waitForPendingWrites()

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try permissions(of: root) == 0o700)
        #expect(try permissions(of: file) == 0o600)
        let rows = await history.load()
        #expect(rows.map(\.filename) == ["new-download.txt"])
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }
}
