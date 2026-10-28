import CoreGraphics
import Foundation
import Testing
@testable import CmuxVNC

/// The RFB decode files read every field from the front of the bytes they were handed (p10-stability-093): a
/// count a decoder got wrong, a short field and a value past its type are `RFBError.protocolViolation` or nil,
/// never a trap. The seeded suites of RFBFuzzTests drive the same paths with hostile servers.
struct RFBDecodeTrapTests {
    @Test func aNegativeReadEndsTheSessionWithATypedError() async throws {
        let reader = RFBReader(transport: ScriptedTransport([1, 2, 3, 4]))
        await #expect(throws: RFBError.self) { try await reader.withBytes(-1) { Array($0) } }
        await #expect(throws: RFBError.self) { try await reader.skip(-4) }
        // The refused reads consumed nothing.
        #expect(try await reader.u32() == 0x0102_0304)
    }

    @Test func fieldsReadBigEndianAndPixelsLittleEndian() async throws {
        let reader = RFBReader(transport: ScriptedTransport([0xAB, 0x01, 0x02, 0xFF, 0xFF, 0xFF, 0xFE, 0x10, 0x20, 0x30, 0x99],
                                                            chunk: 3))
        #expect(try await reader.u8() == 0xAB)
        #expect(try await reader.u16() == 0x0102)
        #expect(try await reader.s32() == -2)
        // B G R X: the X byte never reaches the colour, alpha is forced opaque.
        #expect(try await reader.pixel() == 0xFF30_2010)
    }

    @Test func aStringLongerThanItsLimitIsRefused() async {
        var server = Bytes()
        server.u32(4097)
        let reader = RFBReader(transport: ScriptedTransport(server.data))
        await #expect(throws: RFBError.protocolViolation("string of 4097 bytes")) {
            _ = try await reader.lengthPrefixedString(limit: 4096)
        }
    }

    @Test func aShortPixelFormatIsNoFormat() {
        #expect(RFBPixelFormat(bytes: RFBPixelFormat.bgrx.encoded.prefix(15)) == nil)
        #expect(RFBPixelFormat(bytes: RFBPixelFormat.bgrx.encoded) == .bgrx)
        // Bytes past the sixteenth are not read.
        #expect(RFBPixelFormat(bytes: RFBPixelFormat.bgrx.encoded + [0xFF, 0xFF]) == .bgrx)
    }

    @Test func aPortPastSixteenBitsIsNoEndpoint() throws {
        #expect(VNCEndpoint.parse("host:65536") == nil)
        #expect(VNCEndpoint.parse("host:-1") == nil)
        #expect(try #require(VNCEndpoint.parse("host:65535")).endpoint.port == 65535)
        #expect(try #require(VNCEndpoint.parse("host:99")).endpoint.port == 5999)
        #expect(try #require(VNCEndpoint.parse("vnc://me@[fe80::1]:5901/path")).endpoint == VNCEndpoint(host: "fe80::1", port: 5901))
    }

    /// RFB 3.3 sends the security type as a whole word: one past a byte is refused as unsupported, never cut.
    @Test func aSecurityWordPastAByteIsUnsupported() async {
        var server = Bytes()
        server.data += Array("RFB 003.003\n".utf8)
        server.u32(258)
        let transport = ScriptedTransport(server.data)
        await #expect(throws: RFBError.noSupportedSecurityType([2])) {
            _ = try await RFBHandshake(credentials: VNCCredentials()).run(reader: RFBReader(transport: transport), transport: transport)
        }
    }

    /// A ZRLE palette tile whose packed index names no palette entry is refused, in both palette forms.
    @Test func aZRLEPaletteIndexPastThePaletteIsRefused() throws {
        let framebuffer = Framebuffer(width: 2, height: 1)
        let header = RFBRectangleHeader(x: 0, y: 0, width: 2, height: 1, encoding: RFBEncoding.zrle.rawValue)
        // Packed palette of 3 colours (2 bits per pixel): index 3 is past it.
        var packed = ZRLEParser(bytes: [3] + [UInt8](repeating: 0, count: 9) + [0b1100_0000])
        #expect(throws: RFBError.protocolViolation("ZRLE palette index")) { try packed.decode(header, into: framebuffer) }
        // Palette RLE of 2 colours: index 5 is past it.
        var runs = ZRLEParser(bytes: [130] + [UInt8](repeating: 0, count: 6) + [5])
        #expect(throws: RFBError.protocolViolation("ZRLE palette index")) { try runs.decode(header, into: framebuffer) }
        // A run past the tile.
        var long = ZRLEParser(bytes: [128, 1, 2, 3, 5])
        #expect(throws: RFBError.protocolViolation("ZRLE run overflow")) { try long.decode(header, into: framebuffer) }
    }

    @Test func zrleTilesFillTheirRectangle() throws {
        let framebuffer = Framebuffer(width: 2, height: 2)
        let header = RFBRectangleHeader(x: 0, y: 0, width: 2, height: 2, encoding: RFBEncoding.zrle.rawValue)
        // A packed palette of 2 colours (1 bit per pixel, one byte per row): row 0 = 0 1, row 1 = 1 0.
        var parser = ZRLEParser(bytes: [2, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0b0100_0000, 0b1000_0000])
        try parser.decode(header, into: framebuffer)
        #expect(framebuffer.pixels == [0xFFFF_0000, 0xFF00_00FF, 0xFF00_00FF, 0xFFFF_0000])
    }
}
