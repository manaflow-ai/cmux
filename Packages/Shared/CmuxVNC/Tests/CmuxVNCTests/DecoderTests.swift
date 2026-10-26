import CoreGraphics
import Foundation
import Testing
@testable import CmuxVNC
@testable import CmuxVNCDemoServer

/// Feeds one rectangle body through the decoder from scripted bytes, `chunk` bytes per receive.
func decode(_ header: RFBRectangleHeader, body: [UInt8], into framebuffer: Framebuffer,
            decoder: RFBRectangleDecoder = RFBRectangleDecoder(), chunk: Int = 5) async throws -> RFBRectangleEffect {
    try await decoder.decode(header, reader: RFBReader(transport: ScriptedTransport(body, chunk: chunk)), into: framebuffer)
}

func bgrx(_ pixel: UInt32) -> [UInt8] {
    [UInt8(pixel & 0xFF), UInt8((pixel >> 8) & 0xFF), UInt8((pixel >> 16) & 0xFF), 0]
}

func cpixel(_ pixel: UInt32) -> [UInt8] {
    Array(bgrx(pixel).prefix(3))
}

/// zlib-compresses with a sync flush, as RFB servers do per rectangle (a fresh stream).
func zlibCompress(_ input: [UInt8]) -> [UInt8] {
    Deflater().deflate(input)
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
        framebuffer.blit(x: 0, y: 0, width: 4, height: 1, pixels: pixels[...])
        _ = try await decode(RFBRectangleHeader(x: 1, y: 0, width: 3, height: 1, encoding: 1), body: [0, 0, 0, 0], into: framebuffer)
        pixels = [red, red, green, blue]
        #expect(framebuffer.pixels == pixels)
    }

    /// Raw rows arrive as slices of the reader's buffer at a nonzero start: one receive
    /// buffers the whole body, so row 2 is the slice 8..<16 (no compaction between rows).
    /// The blit indexes from the slice's start, not from 0.
    @Test func rawRowsFromBufferSlices() async throws {
        let framebuffer = Framebuffer(width: 2, height: 2)
        _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 2, height: 2, encoding: 0),
                             body: bgrx(red) + bgrx(green) + bgrx(blue) + bgrx(red), into: framebuffer, chunk: 64)
        #expect(framebuffer.pixels == [red, green, blue, red])
    }

    /// A Hextile raw tile follows its one-byte subencoding mask, so its pixels are the
    /// slice 1..<9 of the reader's buffer (one receive, no compaction).
    @Test func hextileRawTileFromBufferSlice() async throws {
        let framebuffer = Framebuffer(width: 2, height: 1)
        _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 2, height: 1, encoding: 5),
                             body: [UInt8(1)] + bgrx(green) + bgrx(blue), into: framebuffer, chunk: 64)
        #expect(framebuffer.pixels == [green, blue])
    }

    /// CopyRect moving left inside one row, and down over its own rows: no word is read
    /// after the copy overwrote it.
    @Test func copyRectOverlappingLeftAndDown() async throws {
        let black: UInt32 = 0xFF00_0000
        let row = Framebuffer(width: 4, height: 1)
        row.blit(x: 0, y: 0, width: 4, height: 1, pixels: [black, red, green, blue][...])
        _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 3, height: 1, encoding: 1), body: [0, 1, 0, 0], into: row)
        #expect(row.pixels == [red, green, blue, blue])

        let column = Framebuffer(width: 1, height: 3)
        column.blit(x: 0, y: 0, width: 1, height: 3, pixels: [red, green, black][...])
        _ = try await decode(RFBRectangleHeader(x: 0, y: 1, width: 1, height: 2, encoding: 1), body: [0, 0, 0, 0], into: column)
        #expect(column.pixels == [red, red, green])
    }

    /// A blit source shorter than the rectangle draws nothing (the guard, not a read past it).
    @Test func shortBlitSourceIsIgnored() {
        let framebuffer = Framebuffer(width: 2, height: 1)
        framebuffer.blit(x: 0, y: 0, width: 2, height: 1, pixels: [red][...])
        #expect(framebuffer.pixels == [0xFF00_0000, 0xFF00_0000])
    }

    /// The cursor image carries its words as little-endian B G R A bytes.
    @Test func cursorImageBytes() throws {
        let image = try #require(VNCCursor(width: 2, height: 1, hotspotX: 0, hotspotY: 0, pixels: [red, 0x8000_00FF]).makeImage())
        let bytes = try #require(image.dataProvider?.data as Data?)
        #expect([UInt8](bytes) == [0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x80])
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
        framebuffer.blit(x: 0, y: 0, width: 2, height: 1, pixels: [red, blue][...])
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
