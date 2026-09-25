import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("CodexToolFeedSpool")
struct CodexToolFeedSpoolTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test("Incomplete payloads stay private until publication")
    func publicationBoundary() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = CodexToolFeedSpool(directory: dir)
        let payload = Data("{\n\"tool_name\":\"日本語\"\n}".utf8)
        try (Data("pre-tool-use\n".utf8) + payload + Data([0])).write(to: dir.appendingPathComponent("0"))
        #expect(await spool.drain().isEmpty)
        try Data().write(to: dir.appendingPathComponent("0.ready"))
        let records = await spool.drain()
        #expect(records.count == 1)
        #expect(records.first?.event == "pre-tool-use")
        #expect(records.first?.payload == payload)
        #expect(await spool.drain().isEmpty)
        await spool.close()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("Oversized, malformed, and symlink records cannot escape the spool")
    func malformedRecords() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = CodexToolFeedSpool(directory: dir)
        try Data(repeating: 1, count: 70000).write(to: dir.appendingPathComponent("0"))
        try Data("post-tool-use\n{}".utf8).write(to: dir.appendingPathComponent("1"))
        let outside = dir.appendingPathComponent("outside")
        let content = Data("pre-tool-use\n{}\0".utf8)
        try content.write(to: outside)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("2"), withDestinationURL: outside)
        for slot in 0..<3 { try Data().write(to: dir.appendingPathComponent("\(slot).ready")) }
        #expect(await spool.drain().isEmpty)
        #expect(try Data(contentsOf: outside) == content)
        await spool.close()
        #expect(try Data(contentsOf: outside) == content)
    }

    @Test("Private-directory validation rejects cleanup of unrelated directories")
    func rejectsSharedDirectory() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try Data("unrelated".utf8).write(to: dir.appendingPathComponent("0"))
        let spool = CodexToolFeedSpool(directory: dir)
        await spool.close()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("0").path))
    }
}
