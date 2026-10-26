@testable import CmuxNextBrowserImport
import Foundation
import Testing

/// The import's pointer-free reads after p10-stability-070 (strict memory safety): the SQLite row
/// that checks its column, the byte view the CSV and zip readers parse in place, and the secret
/// checks that no longer hand a pointer to the caller. Gated like the import fuzz: agents run it on
/// the fleet, CI does not (Lawrence 2026-10-23).
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_IMPORT_FUZZ"] == "1",
        "set CMUX_IMPORT_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    ),
    .timeLimit(.minutes(1))
)
struct BrowserImportMemorySafetyTests {
    /// A snapshot of an empty file (SQLite reads it as an empty database) with `statements` run on
    /// the private copy.
    private func database(_ statements: [String]) throws -> SQLiteSnapshot {
        let file = FileManager.default.temporaryDirectory.appending(path: "cmux-import-safety-\(UUID().uuidString).sqlite")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let snapshot = try SQLiteSnapshot(copying: file)
        for statement in statements {
            try snapshot.query(statement) { _ in true }
        }
        return snapshot
    }

    @Test func aColumnPastTheResultReadsAsNull() throws {
        let db = try database(["CREATE TABLE t (a INTEGER, b TEXT, c BLOB)", "INSERT INTO t VALUES (7, 'x', x'0102')"])
        // The row is ~Copyable and borrowed for the closure only, so its reads are copied out first.
        var reads: [RowRead] = []
        try db.query("SELECT a, b, c FROM t") { row in
            reads.append(RowRead(integer: row.int64(0), text: row.string(1), blob: row.data(2), integerPast: row.int64(3),
                                 doubleBefore: row.double(-1), textPast: row.string(3), blobPast: row.data(99),
                                 nullPast: row.isNull(3), nullBefore: row.isNull(-1)))
            return true
        }
        #expect(reads == [RowRead(integer: 7, text: "x", blob: Data([1, 2]), integerPast: 0, doubleBefore: 0, textPast: nil,
                                  blobPast: nil, nullPast: true, nullBefore: true)])
    }

    private struct RowRead: Equatable {
        var integer: Int64
        var text: String?
        var blob: Data?
        var integerPast: Int64
        var doubleBefore: Double
        var textPast: String?
        var blobPast: Data?
        var nullPast: Bool
        var nullBefore: Bool
    }

    /// Before: SQL with no statement in it prepared a NULL statement that was then stepped.
    @Test func sqlWithNoStatementIsAQueryFailure() throws {
        let db = try database([])
        #expect(throws: SQLiteSnapshot.Failure.self) {
            try db.query("-- nothing here") { _ in true }
        }
        #expect(db.hasTable("t") == false)
    }

    @Test func aByteViewReadsZeroPastItsEndAndRefusesRangesOutsideIt() {
        let bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x41]
        bytes.withUnsafeBytes { raw in
            let view = unsafe ByteView(raw)
            #expect(view.count == 5)
            #expect(view[4] == 0x41)
            #expect(view[5] == 0)
            #expect(view[-1] == 0)
            #expect(view.littleEndian32(0) == 0x0403_4B50)
            #expect(view.littleEndian32(2) == 0)
            #expect(view.littleEndian16(4) == 0)
            #expect(view.view(4..<5)?.text == "A")
            #expect(view.view(4..<6) == nil)
            #expect(view.view(-1..<2) == nil)
        }
    }

    /// A central directory entry whose name runs past the file is not an archive (no read past it).
    @Test func anArchiveNameLongerThanTheFileIsRefused() throws {
        var zip = [UInt8](repeating: 0, count: 46)
        zip.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x01, 0x02])
        zip[28] = 0xFF
        zip[29] = 0x00
        var end = [UInt8](repeating: 0, count: 22)
        end.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x05, 0x06])
        end[10] = 1
        #expect(throws: ExportArchive.Failure.notAnArchive) {
            try ExportArchive.archive(in: SecretBytes(copying: zip + end))
        }
    }

    @Test func secretChecksWorkInPlace() {
        let secret = SecretBytes(copying: Array("password-check".utf8))
        #expect(secret.starts(with: Array("password".utf8)))
        #expect(!secret.starts(with: Array("password-check!".utf8)))
        #expect(secret.isValidUTF8)
        #expect(!SecretBytes(copying: [0xC3, 0x28]).isValidUTF8)
        #expect(SecretBytes(capacity: 0) { _ in 0 }.isValidUTF8)
        #expect(secret.matches(SecretBytes(copying: Array("password-check".utf8))))
        #expect(!secret.matches(SecretBytes(copying: Array("password-chess".utf8))))
    }

    /// The CSV reader now takes the file's SecretBytes and parses a view of it.
    @Test func aPasswordCSVParsesFromItsSecretBytes() throws {
        let csv = SecretBytes(copying: Array("url,username,password\nhttps://a.example/,me,\"p\"\"w\"\n".utf8))
        let read = try PasswordCSVReader().read(csv)
        #expect(read.logins.count == 1)
        #expect(read.logins.first?.password.matches(SecretBytes(copying: Array("p\"w".utf8))) == true)
        #expect(PasswordCSVHeader.read(SecretBytes(copying: Array("site,secret\nexample.com,x\n".utf8)))?.names == ["site", "secret"])
    }

    @Test func cookieCryptoRoundTripsThroughArrays() throws {
        let crypto = ChromiumCookieCrypto(safeStoragePassword: Data("peanuts".utf8))
        let sealed = try crypto.encrypt("value", hostKey: ".example.com", databaseVersion: 24)
        #expect(try crypto.decrypt(sealed, hostKey: ".example.com", databaseVersion: 24) == "value")
        #expect(throws: ChromiumCookieCrypto.Failure.self) {
            try crypto.decrypt(sealed, hostKey: ".other.com", databaseVersion: 24)
        }
    }

    @Test func aMozLz4SizeThatLiesIsRefused() {
        var file = Array("mozLz40\0".utf8)
        file += [0xFF, 0xFF, 0xFF, 0x0F, 0x00]
        #expect(FirefoxSessionReader().decompress(Data(file)) == nil)
    }
}
