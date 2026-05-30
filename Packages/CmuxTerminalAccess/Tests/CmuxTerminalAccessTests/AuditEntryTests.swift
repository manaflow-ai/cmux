import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct AuditEntryTests {
    @Test func entryShape() {
        let entry = AuditEntry(
            timestamp: Date(timeIntervalSince1970: 0),
            surface: .ref(kind: "surface", ordinal: 1),
            kind: .writeText, byteCount: 4, detail: ["submit": "true"]
        )
        #expect(entry.kind == .writeText)
        #expect(entry.byteCount == 4)
        #expect(entry.detail?["submit"] == "true")
    }

    @Test func entryEncodesAsSnakeCase() throws {
        let entry = AuditEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            surface: .ref(kind: "surface", ordinal: 2),
            kind: .streamOpen, byteCount: 0, detail: nil
        )
        let data = try JSONEncoder().encode(entry)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"byte_count\":0"))
        #expect(json.contains("\"stream_open\""))
        #expect(json.contains("\"surface:2\""))
    }

    @Test func noOpAuditLogAcceptsAllEntries() async {
        let log = NoOpAuditLog()
        await log.record(
            AuditEntry(
                timestamp: Date(),
                surface: .ref(kind: "surface", ordinal: 1),
                kind: .writeRaw, byteCount: 0, detail: nil
            )
        )
    }

    @Test func auditKindCoversD3Cases() {
        let all: Set<AuditKind> = [
            .writeText, .writeKeys, .writeRaw, .writePaste,
            .writeMouse, .writeFocus, .streamOpen, .streamClose,
        ]
        #expect(all.count == 8)
    }

    @Test func auditKindWireValuesAreSnakeCase() {
        #expect(AuditKind.writeText.rawValue == "write_text")
        #expect(AuditKind.writePaste.rawValue == "write_paste")
        #expect(AuditKind.streamOpen.rawValue == "stream_open")
        #expect(AuditKind.streamClose.rawValue == "stream_close")
    }
}
