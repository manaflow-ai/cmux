import Foundation
import Testing
@testable import CMUXMobileCore

/// The module's single IP text conversion (inet_pton / inet_aton / inet_ntop)
/// and the pointer-free big-endian writer that replaced withUnsafeBytes(of:).
@Suite struct CmxIPLiteralTests {
    @Test func strictIPv4ParsesDottedQuadsOnly() throws {
        let literal = try #require(CmxIPLiteral("100.64.1.2", family: .ipv4))
        #expect(literal.bytes == [100, 64, 1, 2])
        #expect(literal.canonicalText == "100.64.1.2")
        #expect(CmxIPLiteral("127.1", family: .ipv4) == nil)
        #expect(CmxIPLiteral("0x7f.0.0.1", family: .ipv4) == nil)
        #expect(CmxIPLiteral("::1", family: .ipv4) == nil)
        #expect(CmxIPLiteral("", family: .ipv4) == nil)
    }

    @Test func strictIPv6ParsesSixteenBytesAndPrintsCanonicalText() throws {
        let literal = try #require(CmxIPLiteral("FD7A:115C:A1E0:0:0:0:0:53", family: .ipv6))
        #expect(literal.bytes == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] + [UInt8](repeating: 0, count: 9) + [0x53])
        #expect(literal.canonicalText == "fd7a:115c:a1e0::53")
        let mapped = try #require(CmxIPLiteral("::ffff:127.0.0.1", family: .ipv6))
        #expect(mapped.bytes == [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 127, 0, 0, 1])
        #expect(CmxIPLiteral("::1%lo0", family: .ipv6) == nil)
        #expect(CmxIPLiteral("1.2.3.4", family: .ipv6) == nil)
    }

    /// inet_aton's legacy forms, the ones a resolver dials for a name-looking host.
    @Test(arguments: [
        ("127.1", [UInt8]([127, 0, 0, 1])),
        ("0177.0.0.1", [127, 0, 0, 1]),
        ("0x7f000001", [127, 0, 0, 1]),
        ("2130706433", [127, 0, 0, 1]),
        ("10.1.2.3", [10, 1, 2, 3]),
    ])
    func resolverIPv4AcceptsLegacyForms(text: String, bytes: [UInt8]) throws {
        let literal = try #require(CmxIPLiteral(resolverIPv4: text))
        #expect(literal.family == .ipv4)
        #expect(literal.bytes == bytes)
    }

    @Test func resolverIPv4RejectsNames() {
        #expect(CmxIPLiteral(resolverIPv4: "localhost") == nil)
        #expect(CmxIPLiteral(resolverIPv4: "::1") == nil)
    }

    @Test func appendBigEndianWritesMostSignificantByteFirst() {
        var data = Data()
        data.appendBigEndian(UInt32(0x0102_0304))
        data.appendBigEndian(UInt64(0x0506_0708_090A_0B0C))
        data.appendBigEndian(UInt8(0xFF))
        #expect([UInt8](data) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0xFF])
        var reader = WireByteReader(data)
        #expect(reader.bigEndian(UInt32.self) == 0x0102_0304)
        #expect(reader.bigEndian(UInt64.self) == 0x0506_0708_090A_0B0C)
    }

    @Test func syncFrameHeaderIsTheBigEndianPayloadLength() throws {
        let frame = try MobileSyncFrameCodec.encodeFrame(Data(repeating: 0xAB, count: 0x0102))
        #expect([UInt8](frame.prefix(4)) == [0, 0, 0x01, 0x02])
        #expect(frame.count == 4 + 0x0102)
    }
}
