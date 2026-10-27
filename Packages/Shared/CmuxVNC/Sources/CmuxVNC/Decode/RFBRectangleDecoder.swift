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
///
/// A rectangle, a subrectangle, a CopyRect source or a screen that does not lie
/// inside what encloses it, and a screen layout with no screen or a screen id
/// listed twice, is refused with `RFBError.protocolViolation`, never
/// clipped, as TigerVNC refuses it (common/rfb/DecodeManager.cxx "Rect too big",
/// RREDecoder.cxx, HextileDecoder.cxx, ModifiablePixelBuffer::copyRect,
/// ScreenSet::validate): the server and this client then never disagree about
/// what is on screen.
final class RFBRectangleDecoder {
    private var zlibStream: ZlibStream?
    private var zrleStream: ZlibStream?
    func decode(_ header: RFBRectangleHeader, reader: RFBReader, into framebuffer: Framebuffer) async throws -> RFBRectangleEffect {
        guard let encoding = RFBEncoding(rawValue: header.encoding) else {
            throw RFBError.protocolViolation("unsupported encoding \(header.encoding)")
        }
        // Pixel rectangles must lie inside the framebuffer: their size bounds every read below.
        if ![.desktopSize, .lastRect, .cursor, .extendedDesktopSize].contains(encoding) {
            try Self.require(x: header.x, y: header.y, width: header.width, height: header.height,
                             inside: framebuffer.width, framebuffer.height, "rectangle", "the framebuffer")
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
            let sourceX = try await reader.u16Int()
            let sourceY = try await reader.u16Int()
            try Self.require(x: sourceX, y: sourceY, width: header.width, height: header.height,
                             inside: framebuffer.width, framebuffer.height, "CopyRect source", "the framebuffer")
            framebuffer.copy(fromX: sourceX, fromY: sourceY, toX: header.x, toY: header.y, width: header.width, height: header.height)
        case .rre:
            try await decodeRRE(header, reader, framebuffer)
        case .hextile:
            try await decodeHextile(header, reader, framebuffer)
        case .zlib:
            let data = try await inflate(reader, stream: &zlibStream, limit: header.width * header.height * 4)
            guard data.count >= header.width * header.height * 4 else { throw RFBError.protocolViolation("short Zlib rectangle") }
            framebuffer.blitBGRX(x: header.x, y: header.y, width: header.width, height: header.height, bytes: data.prefix(header.width * header.height * 4))
        case .zrle:
            // ZRLE's worst case is raw tiles: one subencoding byte per tile plus 3 bytes a pixel.
            let tiles = ((header.width + 63) / 64) * ((header.height + 63) / 64)
            let data = try await inflate(reader, stream: &zrleStream, limit: header.width * header.height * 3 + tiles)
            var parser = ZRLEParser(bytes: data)
            try parser.decode(header, into: framebuffer)
        case .desktopSize:
            try RFBLimits.checkFramebuffer(width: header.width, height: header.height)
            framebuffer.resize(width: header.width, height: header.height)
            return .resized
        case .lastRect:
            return .lastRect
        case .extendedDesktopSize:
            // x is the reason and y the status; a nonzero status answers a failed request.
            let count = try await reader.u8Int()
            try await reader.skip(3)
            // The wire's integers are checked before any becomes a CGRect.
            var wire: [(id: UInt32, x: Int, y: Int, width: Int, height: Int)] = []
            for _ in 0 ..< count {
                let id = try await reader.u32()
                let x = try await reader.u16Int(), y = try await reader.u16Int()
                let w = try await reader.u16Int(), h = try await reader.u16Int()
                _ = try await reader.u32() // flags
                wire.append((id, x, y, w, h))
            }
            guard header.y == 0 else { return .drew }
            try RFBLimits.checkFramebuffer(width: header.width, height: header.height)
            guard !wire.isEmpty else { throw RFBError.protocolViolation("a screen layout with no screen") }
            var ids = Set<UInt32>()
            for screen in wire {
                guard ids.insert(screen.id).inserted else { throw RFBError.protocolViolation("screen \(screen.id) listed twice") }
                guard screen.width > 0, screen.height > 0 else { throw RFBError.protocolViolation("screen \(screen.id) is empty") }
                try Self.require(x: screen.x, y: screen.y, width: screen.width, height: screen.height,
                                 inside: header.width, header.height, "screen \(screen.id)", "the framebuffer")
            }
            framebuffer.resize(width: header.width, height: header.height)
            return .screens(wire.map { VNCScreen(id: $0.id, frame: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) })
        case .cursor:
            return .cursor(try await decodeCursor(header, reader))
        }
        return .drew
    }

    /// Throws unless the rectangle lies inside `width` x `height` at the origin. Every value is
    /// a wire u16 (or a sum of two), so the sums never overflow.
    static func require(x: Int, y: Int, width: Int, height: Int, inside outerWidth: Int, _ outerHeight: Int,
                        _ what: String, _ outer: String) throws {
        guard x >= 0, y >= 0, width >= 0, height >= 0, x + width <= outerWidth, y + height <= outerHeight else {
            throw RFBError.protocolViolation("\(what) \(x),\(y) \(width)x\(height) outside \(outer)")
        }
    }

    private func inflate(_ reader: RFBReader, stream: inout ZlibStream?, limit: Int) async throws -> [UInt8] {
        let length = try await reader.u32Int("a compressed body length")
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
            let x = try await reader.u16Int(), y = try await reader.u16Int()
            let w = try await reader.u16Int(), h = try await reader.u16Int()
            try Self.require(x: x, y: y, width: w, height: h, inside: header.width, header.height, "RRE subrectangle", "its rectangle")
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
                let count = try await reader.u8Int()
                let coloured = mask & subrectsColoured != 0
                for _ in 0 ..< count {
                    let color = coloured ? try await reader.pixel() : foreground
                    let xy = try await reader.u8(), wh = try await reader.u8()
                    let subX = (xy >> 4).widened, subY = (xy & 0x0F).widened, subWidth = (wh >> 4).widened + 1, subHeight = (wh & 0x0F).widened + 1
                    try Self.require(x: subX, y: subY, width: subWidth, height: subHeight,
                                     inside: tileWidth, tileHeight, "Hextile subrectangle", "its tile")
                    framebuffer.fill(x: x + subX, y: y + subY, width: subWidth, height: subHeight, color: color)
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
        var pixels: [UInt32] = []
        pixels.reserveCapacity(w * h)
        for row in 0 ..< h {
            let maskRow = mask.dropFirst(row * maskStride).prefix(maskStride)
            let colourRow = colours.dropFirst(row * w * 4).prefix(w * 4)
            for col in 0 ..< w {
                let maskByte = maskRow.dropFirst(col / 8).first ?? 0
                let shown = maskByte & (UInt8(0x80) >> (col % 8)) != 0
                pixels.append(shown ? colourRow.dropFirst(col * 4).prefix(3).littleEndian(as: UInt32.self) | 0xFF00_0000 : 0)
            }
        }
        return VNCCursor(width: w, height: h, hotspotX: header.x, hotspotY: header.y, pixels: pixels)
    }
}

/// ZRLE (RFC 6143 section 7.7.6) over the inflated bytes of one rectangle:
/// 64x64 tiles of raw, solid, packed-palette, plain RLE or palette RLE
/// pixels. CPIXELs are 3 bytes (B, G, R) for the negotiated format.
///
/// The parser consumes `rest` from the front and builds each tile by appending,
/// so no byte, palette or tile position is an index: short data, a palette
/// index past the palette and a run past the tile are `RFBError.protocolViolation`.
struct ZRLEParser {
    private var rest: ArraySlice<UInt8>
    private var tile: [UInt32] = []

    init(bytes: [UInt8]) {
        rest = ArraySlice(bytes)
        tile.reserveCapacity(64 * 64)
    }

    mutating func decode(_ header: RFBRectangleHeader, into framebuffer: Framebuffer) throws {
        for tileY in stride(from: 0, to: header.height, by: 64) {
            let h = min(64, header.height - tileY)
            for tileX in stride(from: 0, to: header.width, by: 64) {
                let w = min(64, header.width - tileX)
                try decodeTile(width: w, height: h)
                framebuffer.blit(x: header.x + tileX, y: header.y + tileY, width: w, height: h, pixels: tile.prefix(w * h))
            }
        }
    }

    private mutating func byte() throws -> UInt8 {
        guard let next = rest.popFirst() else { throw RFBError.protocolViolation("short ZRLE data") }
        return next
    }

    private mutating func cpixel() throws -> UInt32 {
        guard rest.count >= 3 else { throw RFBError.protocolViolation("short ZRLE data") }
        defer { rest = rest.dropFirst(3) }
        return rest.prefix(3).littleEndian(as: UInt32.self) | 0xFF00_0000
    }

    private mutating func runLength() throws -> Int {
        var length = 1
        while true {
            let next = try byte()
            length += next.widened
            if next != 255 { return length }
        }
    }

    private func paletteColour(_ palette: [UInt32], _ index: Int) throws -> UInt32 {
        guard let colour = palette[checked: index] else { throw RFBError.protocolViolation("ZRLE palette index") }
        return colour
    }

    private mutating func decodeTile(width w: Int, height h: Int) throws {
        let count = w * h
        tile.removeAll(keepingCapacity: true)
        let subencoding = try byte()
        switch subencoding {
        case 0:
            for _ in 0 ..< count { tile.append(try cpixel()) }
        case 1:
            let color = try cpixel()
            tile.append(contentsOf: repeatElement(color, count: count))
        case 2 ... 16:
            var palette: [UInt32] = []
            for _ in 0 ..< subencoding.widened { palette.append(try cpixel()) }
            let bits = subencoding == 2 ? 1 : (subencoding <= 4 ? 2 : 4)
            let mask: UInt8 = subencoding == 2 ? 0b1 : (subencoding <= 4 ? 0b11 : 0b1111)
            for _ in 0 ..< h {
                var current: UInt8 = 0
                var remaining = 0
                for _ in 0 ..< w {
                    if remaining == 0 {
                        current = try byte()
                        remaining = 8
                    }
                    remaining -= bits
                    tile.append(try paletteColour(palette, ((current >> remaining) & mask).widened))
                }
            }
        case 128:
            while tile.count < count {
                let color = try cpixel()
                let length = try runLength()
                guard tile.count + length <= count else { throw RFBError.protocolViolation("ZRLE run overflow") }
                tile.append(contentsOf: repeatElement(color, count: length))
            }
        case 130 ... 255:
            var palette: [UInt32] = []
            for _ in 0 ..< (subencoding - 128).widened { palette.append(try cpixel()) }
            while tile.count < count {
                let value = try byte()
                let color = try paletteColour(palette, (value & 0x7F).widened)
                let length = value & 0x80 != 0 ? try runLength() : 1
                guard tile.count + length <= count else { throw RFBError.protocolViolation("ZRLE run overflow") }
                tile.append(contentsOf: repeatElement(color, count: length))
            }
        default:
            throw RFBError.protocolViolation("ZRLE subencoding \(subencoding)")
        }
    }
}
