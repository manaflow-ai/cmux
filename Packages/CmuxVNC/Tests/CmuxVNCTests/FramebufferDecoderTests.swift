import XCTest
@testable import CmuxVNC

final class FramebufferDecoderTests: XCTestCase {
    /// Little-endian BGRX bytes for a host `0x00RRGGBB` pixel.
    private func pixelBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    func testRawEncoding() async throws {
        let fb = Framebuffer(width: 2, height: 2)
        let colors: [UInt32] = [0x00FF0000, 0x0000FF00, 0x000000FF, 0x00FFFFFF]
        var stream: [UInt8] = []
        for c in colors { stream.append(contentsOf: pixelBytes(c)) }

        let header = RFBRectangleHeader(x: 0, y: 0, width: 2, height: 2, encoding: 0)
        try await RFBRectangleDecoder().decode(header: header, from: InMemoryByteSource(stream), into: fb)

        XCTAssertEqual(fb.pixels, colors)
    }

    func testCopyRectEncoding() async throws {
        let fb = Framebuffer(width: 2, height: 1)
        fb.fill(x: 0, y: 0, width: 1, height: 1, color: 0x00AB_CDEF)
        // CopyRect from (0,0) to (1,0).
        let stream: [UInt8] = [0, 0, 0, 0] // srcX=0, srcY=0
        let header = RFBRectangleHeader(x: 1, y: 0, width: 1, height: 1, encoding: 1)
        try await RFBRectangleDecoder().decode(header: header, from: InMemoryByteSource(stream), into: fb)

        XCTAssertEqual(fb.pixels[1], 0x00AB_CDEF)
    }

    func testRREEncoding() async throws {
        let fb = Framebuffer(width: 4, height: 4)
        let background: UInt32 = 0x0011_2233
        let foreground: UInt32 = 0x00AA_BBCC
        var stream: [UInt8] = [0, 0, 0, 1] // 1 subrect
        stream.append(contentsOf: pixelBytes(background))
        stream.append(contentsOf: pixelBytes(foreground))
        stream.append(contentsOf: [0, 1, 0, 1, 0, 2, 0, 2]) // x=1,y=1,w=2,h=2
        let header = RFBRectangleHeader(x: 0, y: 0, width: 4, height: 4, encoding: 2)
        try await RFBRectangleDecoder().decode(header: header, from: InMemoryByteSource(stream), into: fb)

        XCTAssertEqual(fb.pixels[0], background)           // corner
        XCTAssertEqual(fb.pixels[1 * 4 + 1], foreground)   // inside subrect
        XCTAssertEqual(fb.pixels[2 * 4 + 2], foreground)   // inside subrect
        XCTAssertEqual(fb.pixels[3 * 4 + 3], background)   // outside subrect
    }

    func testHextileSolidBackgroundTile() async throws {
        let fb = Framebuffer(width: 16, height: 16)
        let background: UInt32 = 0x0012_3456
        // One tile, BackgroundSpecified only (mask = 2), no subrects.
        var stream: [UInt8] = [2]
        stream.append(contentsOf: pixelBytes(background))
        let header = RFBRectangleHeader(x: 0, y: 0, width: 16, height: 16, encoding: 5)
        try await RFBRectangleDecoder().decode(header: header, from: InMemoryByteSource(stream), into: fb)

        XCTAssertTrue(fb.pixels.allSatisfy { $0 == background })
    }

    func testHextileRawTile() async throws {
        let fb = Framebuffer(width: 2, height: 2)
        let colors: [UInt32] = [0x00111111, 0x00222222, 0x00333333, 0x00444444]
        var stream: [UInt8] = [1] // Raw bit
        for c in colors { stream.append(contentsOf: pixelBytes(c)) }
        let header = RFBRectangleHeader(x: 0, y: 0, width: 2, height: 2, encoding: 5)
        try await RFBRectangleDecoder().decode(header: header, from: InMemoryByteSource(stream), into: fb)

        XCTAssertEqual(fb.pixels, colors)
    }

    func testHextileForegroundSubrect() async throws {
        let fb = Framebuffer(width: 16, height: 16)
        let background: UInt32 = 0x0000_0000
        let foreground: UInt32 = 0x00FF_FFFF
        // mask = bg(2) | fg(4) | anySubrects(8) = 14, then 1 subrect (uncoloured).
        var stream: [UInt8] = [14]
        stream.append(contentsOf: pixelBytes(background))
        stream.append(contentsOf: pixelBytes(foreground))
        stream.append(1)          // 1 subrect
        stream.append(0x00)       // x=0, y=0
        stream.append(0x00)       // w=1, h=1
        let header = RFBRectangleHeader(x: 0, y: 0, width: 16, height: 16, encoding: 5)
        try await RFBRectangleDecoder().decode(header: header, from: InMemoryByteSource(stream), into: fb)

        XCTAssertEqual(fb.pixels[0], foreground)
        XCTAssertEqual(fb.pixels[1], background)
    }

    func testDesktopSizeResizesFramebuffer() async throws {
        let fb = Framebuffer(width: 4, height: 4)
        let header = RFBRectangleHeader(x: 0, y: 0, width: 8, height: 6, encoding: -223)
        try await RFBRectangleDecoder().decode(header: header, from: InMemoryByteSource([]), into: fb)
        XCTAssertEqual(fb.width, 8)
        XCTAssertEqual(fb.height, 6)
        XCTAssertEqual(fb.pixels.count, 48)
    }

    func testUnknownEncodingThrows() async {
        let fb = Framebuffer(width: 1, height: 1)
        let header = RFBRectangleHeader(x: 0, y: 0, width: 1, height: 1, encoding: 999)
        do {
            try await RFBRectangleDecoder().decode(header: header, from: InMemoryByteSource([]), into: fb)
            XCTFail("expected throw")
        } catch let error as RFBError {
            if case .protocolViolation = error { return }
            XCTFail("unexpected \(error)")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFramebufferResizePreservesTopLeft() {
        let fb = Framebuffer(width: 2, height: 2)
        fb.blit(x: 0, y: 0, width: 2, height: 2, pixels: [1, 2, 3, 4])
        fb.resize(width: 3, height: 3)
        XCTAssertEqual(fb.pixels[0], 1)
        XCTAssertEqual(fb.pixels[1], 2)
        XCTAssertEqual(fb.width, 3)
    }
}
