import Foundation
import Testing
import zlib
@testable import CmuxVNC
@testable import CmuxVNCDemoServer

/// Feeds one rectangle body through the decoder from scripted bytes.
func decode(_ header: RFBRectangleHeader, body: [UInt8], into framebuffer: Framebuffer,
            decoder: RFBRectangleDecoder = RFBRectangleDecoder()) async throws -> RFBRectangleEffect {
    try await decoder.decode(header, reader: RFBReader(transport: ScriptedTransport(body, chunk: 5)), into: framebuffer)
}

func bgrx(_ pixel: UInt32) -> [UInt8] {
    [UInt8(pixel & 0xFF), UInt8((pixel >> 8) & 0xFF), UInt8((pixel >> 16) & 0xFF), 0]
}

func cpixel(_ pixel: UInt32) -> [UInt8] {
    Array(bgrx(pixel).prefix(3))
}

/// zlib-compresses with a sync flush, as RFB servers do per rectangle.
func zlibCompress(_ input: [UInt8]) -> [UInt8] {
    var stream = z_stream()
    deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    defer { deflateEnd(&stream) }
    var source = input
    var output = [UInt8](repeating: 0, count: input.count * 2 + 64)
    let capacity = output.count
    source.withUnsafeMutableBufferPointer { inBuffer in
        output.withUnsafeMutableBufferPointer { outBuffer in
            stream.next_in = inBuffer.baseAddress
            stream.avail_in = uInt(inBuffer.count)
            stream.next_out = outBuffer.baseAddress
            stream.avail_out = uInt(capacity)
            deflate(&stream, Z_SYNC_FLUSH)
        }
    }
    return Array(output.prefix(capacity - Int(stream.avail_out)))
}

struct DecoderTests {
    let red: UInt32 = 0xFFFF_0000, green: UInt32 = 0xFF00_FF00, blue: UInt32 = 0xFF00_00FF

    @Test func rawForcesOpaque() async throws {
        let framebuffer = Framebuffer(width: 2, height: 1)
        _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 2, height: 1, encoding: 0),
                             body: bgrx(red) + bgrx(blue), into: framebuffer)
        #expect(framebuffer.pixels == [red, blue])
        #expect(framebuffer.takeDirty() == CGRect(x: 0, y: 0, width: 2, height: 1))
    }

    @Test func copyRectOverlapping() async throws {
        let framebuffer = Framebuffer(width: 4, height: 1)
        var pixels: [UInt32] = [red, green, blue, 0xFF00_0000]
        pixels.withUnsafeBufferPointer { framebuffer.blit(x: 0, y: 0, width: 4, height: 1, pixels: $0) }
        _ = try await decode(RFBRectangleHeader(x: 1, y: 0, width: 3, height: 1, encoding: 1), body: [0, 0, 0, 0], into: framebuffer)
        pixels = [red, red, green, blue]
        #expect(framebuffer.pixels == pixels)
    }

    @Test func hextileBackgroundAndSubrects() async throws {
        let framebuffer = Framebuffer(width: 16, height: 16)
        // background + foreground + one 2x2 subrect at (1,1).
        let body: [UInt8] = [UInt8(2 | 4 | 8)] + bgrx(blue) + bgrx(red) + [UInt8(1), 0x11, 0x11]
        _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 16, height: 16, encoding: 5), body: body, into: framebuffer)
        #expect(framebuffer.pixels[0] == blue)
        #expect(framebuffer.pixels[1 * 16 + 1] == red)
        #expect(framebuffer.pixels[2 * 16 + 2] == red)
        #expect(framebuffer.pixels[3 * 16 + 3] == blue)
    }

    @Test func zrleTilesShareOneStream() async throws {
        let framebuffer = Framebuffer(width: 4, height: 2)
        let decoder = RFBRectangleDecoder()
        // Rect 1: solid tile. Rect 2: packed palette (2 colours, 1 bit). Rect 3: palette RLE.
        let solid: [UInt8] = [UInt8(1)] + cpixel(green)
        let packed: [UInt8] = [UInt8(2)] + cpixel(red) + cpixel(blue) + [UInt8(0b0101_0000), UInt8(0b1010_0000)]
        let paletteRLE: [UInt8] = [UInt8(130)] + cpixel(red) + cpixel(green) + [UInt8(0x80), 2, 0x81, 4]
        // One deflate stream across rectangles (z_stream must not move: heap-allocated).
        let deflater = Deflater()
        func compress(_ input: [UInt8]) -> [UInt8] { deflater.deflate(input) }
        for (index, tile) in [solid, packed, paletteRLE].enumerated() {
            let compressed = compress(tile)
            var body = Bytes()
            body.u32(compressed.count)
            body.data += compressed
            let header = RFBRectangleHeader(x: 0, y: 0, width: 4, height: 2, encoding: 16)
            _ = try await decode(header, body: body.data, into: framebuffer, decoder: decoder)
            switch index {
            case 0: #expect(framebuffer.pixels == [UInt32](repeating: green, count: 8))
            case 1: #expect(framebuffer.pixels == [red, blue, red, blue, blue, red, blue, red])
            default: #expect(framebuffer.pixels == [red, red, red, green, green, green, green, green])
            }
        }
    }

    @Test func zlibRaw() async throws {
        let framebuffer = Framebuffer(width: 2, height: 1)
        let compressed = zlibCompress(bgrx(green) + bgrx(red))
        var body = Bytes()
        body.u32(compressed.count)
        body.data += compressed
        _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 2, height: 1, encoding: 6), body: body.data, into: framebuffer)
        #expect(framebuffer.pixels == [green, red])
    }

    @Test func cursorAppliesMask() async throws {
        let framebuffer = Framebuffer(width: 1, height: 1)
        let body: [UInt8] = bgrx(red) + bgrx(blue) + [UInt8(0b1000_0000)]
        let effect = try await decode(RFBRectangleHeader(x: 1, y: 0, width: 2, height: 1, encoding: -239), body: body, into: framebuffer)
        #expect(effect == .cursor(VNCCursor(width: 2, height: 1, hotspotX: 1, hotspotY: 0, pixels: [red, 0])))
    }

    @Test func desktopSizeKeepsOverlap() async throws {
        let framebuffer = Framebuffer(width: 2, height: 1)
        [red, blue].withUnsafeBufferPointer { framebuffer.blit(x: 0, y: 0, width: 2, height: 1, pixels: $0) }
        let effect = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 3, height: 2, encoding: -223), body: [], into: framebuffer)
        #expect(effect == .resized)
        #expect(framebuffer.width == 3 && framebuffer.height == 2)
        #expect(Array(framebuffer.pixels.prefix(2)) == [red, blue])
    }

    @Test func unknownEncodingThrows() async {
        await #expect(throws: RFBError.self) {
            _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 1, height: 1, encoding: 7), body: [], into: Framebuffer(width: 1, height: 1))
        }
    }

    @Test func rectangleOutsideTheFramebufferIsRejected() async {
        await #expect(throws: RFBError.self) {
            _ = try await decode(RFBRectangleHeader(x: 1, y: 1, width: 2, height: 2, encoding: 0), body: [], into: Framebuffer(width: 2, height: 2))
        }
    }

    @Test func hugeCursorIsRejected() async {
        await #expect(throws: RFBError.self) {
            _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 4000, height: 4000, encoding: -239), body: [], into: Framebuffer(width: 1, height: 1))
        }
    }

    @Test func hugeDesktopSizeIsRejected() async {
        await #expect(throws: RFBError.self) {
            _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 65535, height: 65535, encoding: -223), body: [], into: Framebuffer(width: 1, height: 1))
        }
    }

    @Test func inflateStopsAtTheRectangleBound() async {
        // 64 KB of zeros compresses to a few hundred bytes: far past a 2x1 rectangle.
        let compressed = zlibCompress([UInt8](repeating: 0, count: 1 << 16))
        var body = Bytes()
        body.u32(compressed.count)
        body.data += compressed
        await #expect(throws: RFBError.self) {
            _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 2, height: 1, encoding: 6), body: body.data, into: Framebuffer(width: 2, height: 1))
        }
    }
}
