@testable import CmuxNextApp
import Darwin
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

    @Test func aSymlinkedMetadataDirectoryIsRejectedWithoutTouchingItsTarget() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-download-history-\(UUID().uuidString)", isDirectory: true)
        let external = base.appendingPathComponent("outside", isDirectory: true)
        let linked = base.appendingPathComponent("browser", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: external.path)
        let target = external.appendingPathComponent("downloads.json")
        try outsideDocument().write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)
        defer { try? FileManager.default.removeItem(at: base) }

        let rows = await BrowserDownloadHistory(url: linked.appendingPathComponent("downloads.json")).load()

        #expect(rows.isEmpty)
        #expect(try permissions(of: external) == 0o755)
        #expect(try permissions(of: target) == 0o644)
    }

    @Test func aSymlinkedMetadataFileIsRejectedWithoutTouchingItsTarget() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-download-history-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("browser", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = base.appendingPathComponent("outside.json")
        try outsideDocument().write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let linked = root.appendingPathComponent("downloads.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: base) }

        let rows = await BrowserDownloadHistory(url: linked).load()

        #expect(rows.isEmpty)
        #expect(try permissions(of: target) == 0o644)
    }

    @Test func permissiveExtendedACLsAreRemoved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-download-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("downloads.json")
        try Data(#"{"downloads":[]}"#.utf8).write(to: file)
        try await addEveryoneReadACL(to: root)
        try await addEveryoneReadACL(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try extendedACLSize(of: root) > 0)
        #expect(try extendedACLSize(of: file) > 0)

        _ = await BrowserDownloadHistory(url: file).load()

        #expect(try extendedACLSize(of: root) == 0)
        #expect(try extendedACLSize(of: file) == 0)
    }

    private func outsideDocument() -> Data {
        Data(#"{"downloads":[{"filename":"outside.txt","status":"finished","received":1}]}"#.utf8)
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }

    private nonisolated func addEveryoneReadACL(to url: URL) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["+a", "everyone allow read", url.path]
            try process.run()
            // concurrency-allow: test-only child process wait runs in this detached task.
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw POSIXError(.EACCES) }
        }.value
    }

    private func extendedACLSize(of url: URL) throws -> Int {
        guard let acl = url.path.withCString({ acl_get_file($0, ACL_TYPE_EXTENDED) }) else {
            if errno == ENOENT { return 0 }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return Int(length)
    }
}
