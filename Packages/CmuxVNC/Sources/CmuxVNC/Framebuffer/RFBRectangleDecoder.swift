import Foundation

/// Decodes the body of a single `FramebufferUpdate` rectangle into a
/// ``Framebuffer``. Supports Raw, CopyRect, RRE, and Hextile encodings, plus
/// the DesktopSize pseudo-encoding. Unknown encodings throw rather than
/// silently desync the stream.
public struct RFBRectangleDecoder: Sendable {
    public init() {}

    public func decode(
        header: RFBRectangleHeader,
        from source: any RFBByteSource,
        into framebuffer: Framebuffer
    ) async throws {
        switch RFBClientMessage.Encoding(rawValue: header.encoding) {
        case .raw:
            try await decodeRaw(header, source, framebuffer)
        case .copyRect:
            try await decodeCopyRect(header, source, framebuffer)
        case .rre:
            try await decodeRRE(header, source, framebuffer)
        case .hextile:
            try await decodeHextile(header, source, framebuffer)
        case .desktopSize:
            framebuffer.resize(width: header.width, height: header.height)
        default:
            throw RFBError.protocolViolation("unsupported encoding \(header.encoding)")
        }
    }

    private func decodeRaw(
        _ header: RFBRectangleHeader,
        _ source: any RFBByteSource,
        _ framebuffer: Framebuffer
    ) async throws {
        let pixels = try await source.readPixels(count: header.width * header.height)
        framebuffer.blit(x: header.x, y: header.y, width: header.width, height: header.height, pixels: pixels)
    }

    private func decodeCopyRect(
        _ header: RFBRectangleHeader,
        _ source: any RFBByteSource,
        _ framebuffer: Framebuffer
    ) async throws {
        let srcX = try await source.readUInt16()
        let srcY = try await source.readUInt16()
        framebuffer.copyRect(
            srcX: Int(srcX),
            srcY: Int(srcY),
            toX: header.x,
            toY: header.y,
            width: header.width,
            height: header.height
        )
    }

    private func decodeRRE(
        _ header: RFBRectangleHeader,
        _ source: any RFBByteSource,
        _ framebuffer: Framebuffer
    ) async throws {
        let subrectCount = try await source.readUInt32()
        let background = try await source.readPixel()
        framebuffer.fill(x: header.x, y: header.y, width: header.width, height: header.height, color: background)
        for _ in 0 ..< subrectCount {
            let color = try await source.readPixel()
            let sx = try await source.readUInt16()
            let sy = try await source.readUInt16()
            let sw = try await source.readUInt16()
            let sh = try await source.readUInt16()
            framebuffer.fill(
                x: header.x + Int(sx),
                y: header.y + Int(sy),
                width: Int(sw),
                height: Int(sh),
                color: color
            )
        }
    }

    private func decodeHextile(
        _ header: RFBRectangleHeader,
        _ source: any RFBByteSource,
        _ framebuffer: Framebuffer
    ) async throws {
        // Subencoding mask bits.
        let raw: UInt8 = 1
        let backgroundSpecified: UInt8 = 2
        let foregroundSpecified: UInt8 = 4
        let anySubrects: UInt8 = 8
        let subrectsColoured: UInt8 = 16

        var background: UInt32 = 0xFF00_0000
        var foreground: UInt32 = 0xFFFF_FFFF

        var tileY = 0
        while tileY < header.height {
            let tileHeight = min(16, header.height - tileY)
            var tileX = 0
            while tileX < header.width {
                let tileWidth = min(16, header.width - tileX)
                let originX = header.x + tileX
                let originY = header.y + tileY

                let mask = try await source.readUInt8()
                if mask & raw != 0 {
                    let pixels = try await source.readPixels(count: tileWidth * tileHeight)
                    framebuffer.blit(x: originX, y: originY, width: tileWidth, height: tileHeight, pixels: pixels)
                } else {
                    if mask & backgroundSpecified != 0 {
                        background = try await source.readPixel()
                    }
                    if mask & foregroundSpecified != 0 {
                        foreground = try await source.readPixel()
                    }
                    framebuffer.fill(x: originX, y: originY, width: tileWidth, height: tileHeight, color: background)
                    if mask & anySubrects != 0 {
                        let count = try await source.readUInt8()
                        let coloured = mask & subrectsColoured != 0
                        for _ in 0 ..< count {
                            let color = coloured ? try await source.readPixel() : foreground
                            let xy = try await source.readUInt8()
                            let wh = try await source.readUInt8()
                            let subX = Int(xy >> 4)
                            let subY = Int(xy & 0x0F)
                            let subW = Int(wh >> 4) + 1
                            let subH = Int(wh & 0x0F) + 1
                            framebuffer.fill(
                                x: originX + subX,
                                y: originY + subY,
                                width: subW,
                                height: subH,
                                color: color
                            )
                        }
                    }
                }
                tileX += 16
            }
            tileY += 16
        }
    }
}
