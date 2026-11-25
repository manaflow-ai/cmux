import CoreGraphics
import Foundation

/// One `FramebufferUpdate` rectangle header.
struct RFBRectangleHeader: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var encoding: Int32
}

/// What a rectangle did besides drawing.
enum RFBRectangleEffect: Equatable {
    case drew
    case resized
    case cursor(VNCCursor)
    /// ExtendedDesktopSize: the framebuffer may have resized, and its screens.
    case screens([VNCScreen])
    /// LastRect: the update ends here.
    case lastRect
}

/// Decodes rectangle bodies into the framebuffer. Keeps the per-connection
/// zlib streams of the Zlib and ZRLE encodings.
final class RFBRectangleDecoder {
    private var zlibStream: ZlibStream?
    private var zrleStream: ZlibStream?
    func decode(_ header: RFBRectangleHeader, reader: RFBReader, into framebuffer: Framebuffer) async throws -> RFBRectangleEffect {
        guard let encoding = RFBEncoding(rawValue: header.encoding) else {
            throw RFBError.protocolViolation("unsupported encoding \(header.encoding)")
        }
        // Pixel rectangles must lie inside the framebuffer: their size bounds every read below.
        if ![.desktopSize, .lastRect, .cursor, .extendedDesktopSize].contains(encoding) {
            guard header.x + header.width <= framebuffer.width, header.y + header.height <= framebuffer.height else {
                throw RFBError.protocolViolation("rectangle \(header.x),\(header.y) \(header.width)x\(header.height) outside the framebuffer")
            }
        }
        switch encoding {
        case .raw:
            // Row by row, so a large rectangle never sits whole in the read buffer.
            for row in 0 ..< header.height {
                try await reader.withBytes(header.width * 4) { bytes in
                    framebuffer.blitBGRX(x: header.x, y: header.y + row, width: header.width, height: 1, bytes: bytes)
                }
            }
        case .copyRect:
            let sourceX = Int(try await reader.u16())
            let sourceY = Int(try await reader.u16())
            framebuffer.copy(fromX: sourceX, fromY: sourceY, toX: header.x, toY: header.y, width: header.width, height: header.height)
        case .rre:
            try await decodeRRE(header, reader, framebuffer)
        case .hextile:
            try await decodeHextile(header, reader, framebuffer)
        case .zlib:
            let data = try await inflate(reader, stream: &zlibStream, limit: header.width * header.height * 4)
            guard data.count >= header.width * header.height * 4 else { throw RFBError.protocolViolation("short Zlib rectangle") }
            data.withUnsafeBufferPointer { bytes in
                framebuffer.blitBGRX(x: header.x, y: header.y, width: header.width, height: header.height, bytes: bytes)
            }
        case .zrle:
            // ZRLE's worst case is raw tiles: one subencoding byte per tile plus 3 bytes a pixel.
            let tiles = ((header.width + 63) / 64) * ((header.height + 63) / 64)
            let data = try await inflate(reader, stream: &zrleStream, limit: header.width * header.height * 3 + tiles)
            try data.withUnsafeBufferPointer { bytes in
                var parser = ZRLEParser(bytes: bytes)
                try parser.decode(header, into: framebuffer)
            }
        case .desktopSize:
            try RFBLimits.checkFramebuffer(width: header.width, height: header.height)
            framebuffer.resize(width: header.width, height: header.height)
            return .resized
        case .lastRect:
            return .lastRect
        case .extendedDesktopSize:
            // x is the reason and y the status; a nonzero status answers a failed request.
            let count = Int(try await reader.u8())
            try await reader.skip(3)
            var screens: [VNCScreen] = []
            for _ in 0 ..< count {
                let id = try await reader.u32()
                let x = Int(try await reader.u16()), y = Int(try await reader.u16())
                let w = Int(try await reader.u16()), h = Int(try await reader.u16())
                _ = try await reader.u32() // flags
                screens.append(VNCScreen(id: id, frame: CGRect(x: x, y: y, width: w, height: h)))
            }
            guard header.y == 0 else { return .drew }
            try RFBLimits.checkFramebuffer(width: header.width, height: header.height)
            framebuffer.resize(width: header.width, height: header.height)
            return .screens(screens)
        case .cursor:
            return .cursor(try await decodeCursor(header, reader))
        }
        return .drew
    }

    private func inflate(_ reader: RFBReader, stream: inout ZlibStream?, limit: Int) async throws -> [UInt8] {
        let length = Int(try await reader.u32())
        guard length <= RFBLimits.maxCompressedBytes else { throw RFBError.protocolViolation("compressed body of \(length) bytes") }
        let inflater = try stream ?? ZlibStream()
        stream = inflater
        return try await reader.withBytes(length) { try inflater.inflate($0, limit: limit) }
    }

    private func decodeRRE(_ header: RFBRectangleHeader, _ reader: RFBReader, _ framebuffer: Framebuffer) async throws {
        let count = try await reader.u32()
        let background = try await reader.pixel()
        framebuffer.fill(x: header.x, y: header.y, width: header.width, height: header.height, color: background)
        for _ in 0 ..< count {
            let color = try await reader.pixel()
            let x = Int(try await reader.u16()), y = Int(try await reader.u16())
            let w = Int(try await reader.u16()), h = Int(try await reader.u16())
            framebuffer.fill(x: header.x + x, y: header.y + y, width: w, height: h, color: color)
        }
    }

    private func decodeHextile(_ header: RFBRectangleHeader, _ reader: RFBReader, _ framebuffer: Framebuffer) async throws {
        let raw: UInt8 = 1, backgroundSpecified: UInt8 = 2, foregroundSpecified: UInt8 = 4
        let anySubrects: UInt8 = 8, subrectsColoured: UInt8 = 16
        var background: UInt32 = 0xFF00_0000
        var foreground: UInt32 = 0xFFFF_FFFF
        for tileY in stride(from: 0, to: header.height, by: 16) {
            let tileHeight = min(16, header.height - tileY)
            for tileX in stride(from: 0, to: header.width, by: 16) {
                let tileWidth = min(16, header.width - tileX)
                let x = header.x + tileX, y = header.y + tileY
                let mask = try await reader.u8()
                if mask & raw != 0 {
                    try await reader.withBytes(tileWidth * tileHeight * 4) { bytes in
                        framebuffer.blitBGRX(x: x, y: y, width: tileWidth, height: tileHeight, bytes: bytes)
                    }
                    continue
                }
                if mask & backgroundSpecified != 0 { background = try await reader.pixel() }
                if mask & foregroundSpecified != 0 { foreground = try await reader.pixel() }
                framebuffer.fill(x: x, y: y, width: tileWidth, height: tileHeight, color: background)
                guard mask & anySubrects != 0 else { continue }
                let count = Int(try await reader.u8())
                let coloured = mask & subrectsColoured != 0
                for _ in 0 ..< count {
                    let color = coloured ? try await reader.pixel() : foreground
                    let xy = try await reader.u8(), wh = try await reader.u8()
                    framebuffer.fill(x: x + Int(xy >> 4), y: y + Int(xy & 0x0F),
                                     width: Int(wh >> 4) + 1, height: Int(wh & 0x0F) + 1, color: color)
                }
            }
        }
    }

    private func decodeCursor(_ header: RFBRectangleHeader, _ reader: RFBReader) async throws -> VNCCursor {
        let w = header.width, h = header.height
        guard w <= RFBLimits.maxCursorSide, h <= RFBLimits.maxCursorSide else {
            throw RFBError.protocolViolation("cursor \(w)x\(h) is too large")
        }
        let colours = try await reader.bytes(w * h * 4)
        let maskStride = (w + 7) / 8
        let mask = try await reader.bytes(maskStride * h)
        var pixels = [UInt32](repeating: 0, count: w * h)
        for row in 0 ..< h {
            for col in 0 ..< w where mask[row * maskStride + col / 8] & (0x80 >> UInt8(col % 8)) != 0 {
                let index = (row * w + col) * 4
                pixels[row * w + col] = UInt32(colours[index]) | UInt32(colours[index + 1]) << 8
                    | UInt32(colours[index + 2]) << 16 | 0xFF00_0000
            }
        }
        return VNCCursor(width: w, height: h, hotspotX: header.x, hotspotY: header.y, pixels: pixels)
    }
}

/// ZRLE (RFC 6143 section 7.7.6) over the inflated bytes of one rectangle:
/// 64x64 tiles of raw, solid, packed-palette, plain RLE or palette RLE
/// pixels. CPIXELs are 3 bytes (B, G, R) for the negotiated format.
struct ZRLEParser {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var offset = 0
    private var tile = [UInt32](repeating: 0, count: 64 * 64)

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    mutating func decode(_ header: RFBRectangleHeader, into framebuffer: Framebuffer) throws {
        for tileY in stride(from: 0, to: header.height, by: 64) {
            let h = min(64, header.height - tileY)
            for tileX in stride(from: 0, to: header.width, by: 64) {
                let w = min(64, header.width - tileX)
                try decodeTile(width: w, height: h)
                tile.withUnsafeBufferPointer { pixels in
                    framebuffer.blit(x: header.x + tileX, y: header.y + tileY, width: w, height: h,
                                     pixels: UnsafeBufferPointer(rebasing: pixels[0 ..< w * h]))
                }
            }
        }
    }

    private mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw RFBError.protocolViolation("short ZRLE data") }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func cpixel() throws -> UInt32 {
        guard offset + 3 <= bytes.count else { throw RFBError.protocolViolation("short ZRLE data") }
        defer { offset += 3 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | 0xFF00_0000
    }

    private mutating func runLength() throws -> Int {
        var length = 1
        while true {
            let next = try byte()
            length += Int(next)
            if next != 255 { return length }
        }
    }

    private mutating func decodeTile(width w: Int, height h: Int) throws {
        let count = w * h
        let subencoding = try byte()
        switch subencoding {
        case 0:
            for index in 0 ..< count { tile[index] = try cpixel() }
        case 1:
            let color = try cpixel()
            for index in 0 ..< count { tile[index] = color }
        case 2 ... 16:
            var palette: [UInt32] = []
            for _ in 0 ..< Int(subencoding) { palette.append(try cpixel()) }
            let bits = subencoding == 2 ? 1 : (subencoding <= 4 ? 2 : 4)
            let mask = UInt8((1 << bits) - 1)
            for row in 0 ..< h {
                var current: UInt8 = 0
                var remaining = 0
                for col in 0 ..< w {
                    if remaining == 0 {
                        current = try byte()
                        remaining = 8
                    }
                    remaining -= bits
                    let index = Int((current >> UInt8(remaining)) & mask)
                    guard index < palette.count else { throw RFBError.protocolViolation("ZRLE palette index") }
                    tile[row * w + col] = palette[index]
                }
            }
        case 128:
            var filled = 0
            while filled < count {
                let color = try cpixel()
                let length = try runLength()
                guard filled + length <= count else { throw RFBError.protocolViolation("ZRLE run overflow") }
                for index in filled ..< filled + length { tile[index] = color }
                filled += length
            }
        case 130 ... 255:
            var palette: [UInt32] = []
            for _ in 0 ..< Int(subencoding - 128) { palette.append(try cpixel()) }
            var filled = 0
            while filled < count {
                let value = try byte()
                let index = Int(value & 0x7F)
                guard index < palette.count else { throw RFBError.protocolViolation("ZRLE palette index") }
                let length = value & 0x80 != 0 ? try runLength() : 1
                guard filled + length <= count else { throw RFBError.protocolViolation("ZRLE run overflow") }
                for position in filled ..< filled + length { tile[position] = palette[index] }
                filled += length
            }
        default:
            throw RFBError.protocolViolation("ZRLE subencoding \(subencoding)")
        }
    }
}
