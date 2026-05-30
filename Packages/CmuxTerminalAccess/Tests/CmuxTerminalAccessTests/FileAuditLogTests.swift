import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct FileAuditLogTests {
    private func tempURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audit.jsonl")
    }

    @Test func appendsOneJSONLinePerEvent() async throws {
        let url = try tempURL()
        let log = FileAuditLog(url: url)
        await log.record(
            AuditEntry(
                timestamp: Date(timeIntervalSince1970: 0),
                surface: .ref(kind: "surface", ordinal: 1),
                kind: .writeText, byteCount: 4,
                detail: ["submit": "true"]
            )
        )
        await log.record(
            AuditEntry(
                timestamp: Date(timeIntervalSince1970: 1),
                surface: .ref(kind: "surface", ordinal: 1),
                kind: .writeRaw, byteCount: 32, detail: nil
            )
        )
        let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"kind\":\"write_text\""))
        #expect(lines[1].contains("\"byte_count\":32"))
    }

    @Test func enforces0600OnFirstWriteAndReopen() async throws {
        let url = try tempURL()
        // Pre-create the file with mode 0644 to simulate stale state.
        FileManager.default.createFile(
            atPath: url.path, contents: Data(),
            attributes: [.posixPermissions: 0o644]
        )
        let log = FileAuditLog(url: url)
        await log.record(
            AuditEntry(
                timestamp: Date(),
                surface: .ref(kind: "surface", ordinal: 1),
                kind: .writeText, byteCount: 1, detail: nil
            )
        )
        let perms = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                     as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)

        // Loosen the permissions, write another line, and verify it
        // clamps back to 0600 on the next record (covers the "every
        // open" defence).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666], ofItemAtPath: url.path
        )
        await log.record(
            AuditEntry(
                timestamp: Date(),
                surface: .ref(kind: "surface", ordinal: 1),
                kind: .writeText, byteCount: 2, detail: nil
            )
        )
        let permsAfter = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                          as? NSNumber)?.intValue ?? 0
        #expect(permsAfter == 0o600)
    }

    @Test func createsFileWith0600WhenAbsent() async throws {
        let url = try tempURL()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let log = FileAuditLog(url: url)
        await log.record(
            AuditEntry(
                timestamp: Date(),
                surface: .ref(kind: "surface", ordinal: 1),
                kind: .streamOpen, byteCount: 0, detail: nil
            )
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
        let perms = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                     as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }
}
