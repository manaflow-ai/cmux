@testable import CmuxNextBrowserImport
import Foundation
import Testing

/// The import readers after p10-stability-094 (decode-path wave 2): every field of a browser's file is read
/// from the front of what is left, so a count or offset the file lies about is the reader's typed error or
/// skip, never an index past the end. Each case is a length at the edge of its field; the well-formed case
/// beside it shows the rewrite reads the same values as before. Gated like the import fuzz: agents run it on
/// the fleet, CI does not (Lawrence 2026-10-23).
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_IMPORT_FUZZ"] == "1",
        "set CMUX_IMPORT_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    ),
    .timeLimit(.minutes(1))
)
struct BrowserImportDecodeTrapTests {
    private func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    @Test func aPickleReadsItsFieldsAndRefusesALengthPastTheEnd() {
        // size, int32 7, string "ab" (padded to 4), string16 "hi".
        let good: [UInt8] = [le32(20), le32(7), le32(2), Array("ab".utf8), [0, 0], le32(2), [0x68, 0, 0x69, 0]].flatMap { $0 }
        var pickle = PickleReader(Data(good))
        #expect(pickle?.int32() == 7)
        #expect(pickle?.string() == "ab")
        #expect(pickle?.string16() == "hi")
        #expect(pickle?.int32() == nil)

        for length: UInt32 in [3, 0x7FFF_FFFF, 0xFFFF_FFFF] {
            var utf8 = PickleReader(raw: Data(le32(length) + Array("ab".utf8)))
            #expect(utf8.string() == nil, "UTF-8 length \(length)")
            var utf16 = PickleReader(raw: Data(le32(length) + [0x68, 0]))
            #expect(utf16.string16() == nil, "UTF-16 length \(length)")
        }
        #expect(PickleReader(Data(le32(0xFFFF_FFFF))) == nil)
        #expect(PickleReader(Data([1, 0])) == nil)
    }

    @Test func aDERLengthPastTheBlobIsMalformed() throws {
        // SEQUENCE { INTEGER 5, OCTET STRING 01 02 }, the second length in long form.
        let good: [UInt8] = [0x30, 0x08, 0x02, 0x01, 0x05, 0x04, 0x81, 0x02, 0x01, 0x02]
        let root = try NSSDER(good)
        #expect(try root.child(0, tag: NSSDER.integer).smallInteger() == 5)
        #expect(try root.child(1, tag: NSSDER.octetString).content == [1, 2])
        #expect(throws: NSSDER.Malformed.self) { try root.child(2, tag: NSSDER.integer) }

        let lies: [[UInt8]] = [
            [0x04, 0x84, 0xFF, 0xFF, 0xFF, 0xFF, 0x00],  // a 4-octet length of 4 GiB
            [0x04, 0x85, 0, 0, 0, 0, 1, 0],               // five length octets
            [0x04, 0x80],                                   // indefinite length
            [0x04, 0x82, 0x01],                             // the length's own octets cut off
            [0x04, 0x03, 0x01],                             // content cut off
            [0x30],                                         // no length
            good + [0x00],                                  // trailing bytes
        ]
        for blob in lies {
            #expect(throws: NSSDER.Malformed.self, "\(blob)") { try NSSDER(blob) }
        }
    }

    @Test func safariCookiesWithCountsAndOffsetsPastTheFileAreMalformed() {
        let header = Array("cook".utf8)
        // Each file is its parts joined (one long `+` chain is past what the Linux type checker solves).
        let files: [[UInt8]] = [
            [header, [0xFF, 0xFF, 0xFF, 0xFF]],                             // 4 billion pages, no sizes
            [header, [0, 0, 0, 1], [0xFF, 0xFF, 0xFF, 0xFF]],               // one page of 4 GiB
            [header, [0, 0, 0, 1], [0, 0, 0, 16], [0, 0, 1, 0], le32(0xFFFF_FFFF), le32(0xFFFF_FFF0), [0, 0, 0, 0]],
        ].map { $0.flatMap { $0 } }
        for file in files {
            #expect(throws: CookieImportError.self, "\(file)") { try SafariBinaryCookies().parse(Data(file)) }
        }
        #expect(throws: CookieImportError.self) { try SafariBinaryCookies().parse(Data(Array("cool".utf8) + [0, 0, 0, 0])) }
        #expect(throws: Never.self) { try SafariBinaryCookies().parse(Data(header + [0, 0, 0, 0])) }
    }

    @Test func aSessionCommandCutOffEndsTheReadAndKeepsTheCommandsBefore() {
        let file = Array("SNSS".utf8) + le32(1)
        // A command of 0xFFFF bytes in a file that holds three.
        #expect(ChromiumSessionReader().parse(Data(file + [0xFF, 0xFF, 0x06])).items.isEmpty)
        #expect(ChromiumSessionReader().parse(Data(file + [0x00, 0x00, 0x06])).items.isEmpty)
        #expect(ChromiumSessionReader().parse(Data(Array("SNSS".utf8) + [1, 0])).items.isEmpty)
    }

    @Test func aMozLz4SizePastTheBlockIsNotDecompressed() {
        let file = Array("mozLz40\0".utf8) + le32(0xFFFF_FFFF) + [0x10, 0x41]
        #expect(FirefoxSessionReader().decompress(Data(file)) == nil)
        #expect(FirefoxSessionReader().decompress(Data(Array("mozLz40\0".utf8) + [1, 0, 0])) == nil)
    }

    @Test func theCSVWebsiteSniffReadsTheFieldInPlace() {
        func header(_ csv: String) -> PasswordCSVHeader? {
            PasswordCSVHeader.read(SecretBytes(copying: Array(csv.utf8)))
        }
        // A website column found by `://`, by `www.` and by a dotted word; a lone colon at the end is none.
        #expect(header("site,secret\nhttps://a.example,x\n")?.names == ["site", "secret"])
        #expect(header("site,secret\n  WWW.a ,x\n")?.rows == 1)
        #expect(header("site,secret\nexample.com,x\n") != nil)
        #expect(header("site,secret\nhttps:,x\n  ,y\nhttp:/,z\n") == nil)
    }
}
