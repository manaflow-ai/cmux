import Foundation

/// A 32-bit BGRX pixel buffer that mirrors the remote screen.
///
/// Pixels are stored as little-endian `UInt32` values (`0x00RRGGBB`), which is
/// the format cmux negotiates with `SetPixelFormat`, so a `CGImage` can be
/// built directly over the backing store with no conversion.
///
/// Marked `@unchecked Sendable` because it is confined to the single read loop
/// of one ``RFBClient`` actor: the decoder writes it, the loop snapshots it, and
/// nothing else holds a reference. Hand-offs to the UI always go through the
/// immutable ``snapshot()`` (`VNCFrameSnapshot`), never this instance.
public final class Framebuffer: @unchecked Sendable {
    public private(set) var width: Int
    public private(set) var height: Int
    /// Row-major BGRX pixels, `width * height` long.
    public private(set) var pixels: [UInt32]

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixels = [UInt32](repeating: 0xFF00_0000, count: self.width * self.height)
    }

    /// Resizes the buffer (used by the DesktopSize pseudo-encoding), preserving
    /// the overlapping top-left region so a live resize does not flash black.
    public func resize(width newWidth: Int, height newHeight: Int) {
        let w = max(0, newWidth)
        let h = max(0, newHeight)
        guard w != width || h != height else { return }
        var next = [UInt32](repeating: 0xFF00_0000, count: w * h)
        let copyW = min(w, width)
        let copyH = min(h, height)
        if copyW > 0 {
            pixels.withUnsafeBufferPointer { src in
                next.withUnsafeMutableBufferPointer { dst in
                    for row in 0 ..< copyH {
                        let from = row * width
                        let to = row * w
                        dst.baseAddress!.advanced(by: to)
                            .update(from: src.baseAddress!.advanced(by: from), count: copyW)
                    }
                }
            }
        }
        pixels = next
        width = w
        height = h
    }

    /// Fills an axis-aligned rectangle with a single colour.
    public func fill(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, color: UInt32) {
        guard rectWidth > 0, rectHeight > 0 else { return }
        let clampedX = max(0, x)
        let clampedY = max(0, y)
        let maxX = min(width, x + rectWidth)
        let maxY = min(height, y + rectHeight)
        guard maxX > clampedX, maxY > clampedY else { return }
        pixels.withUnsafeMutableBufferPointer { buffer in
            for row in clampedY ..< maxY {
                let base = row * width
                for col in clampedX ..< maxX {
                    buffer[base + col] = color
                }
            }
        }
    }

    /// Writes a tightly-packed run of BGRX pixels into a rectangle, row by row.
    public func blit(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, pixels source: [UInt32]) {
        guard rectWidth > 0, rectHeight > 0 else { return }
        guard source.count >= rectWidth * rectHeight else { return }
        pixels.withUnsafeMutableBufferPointer { dst in
            source.withUnsafeBufferPointer { src in
                for row in 0 ..< rectHeight {
                    let destRow = y + row
                    guard destRow >= 0, destRow < height else { continue }
                    let srcBase = row * rectWidth
                    let dstBase = destRow * width
                    for col in 0 ..< rectWidth {
                        let destCol = x + col
                        guard destCol >= 0, destCol < width else { continue }
                        dst[dstBase + destCol] = src[srcBase + col]
                    }
                }
            }
        }
    }

    /// Copies a rectangle from one location to another (CopyRect encoding).
    /// Handles overlap by choosing a row/column iteration order that does not
    /// clobber not-yet-read source pixels.
    public func copyRect(srcX: Int, srcY: Int, toX: Int, toY: Int, width rectWidth: Int, height rectHeight: Int) {
        guard rectWidth > 0, rectHeight > 0 else { return }
        pixels.withUnsafeMutableBufferPointer { buffer in
            let rowOrder: StrideThrough<Int> = toY > srcY
                ? stride(from: rectHeight - 1, through: 0, by: -1)
                : stride(from: 0, through: rectHeight - 1, by: 1)
            for row in rowOrder {
                let sy = srcY + row
                let dy = toY + row
                guard sy >= 0, sy < height, dy >= 0, dy < height else { continue }
                let colOrder: StrideThrough<Int> = toX > srcX
                    ? stride(from: rectWidth - 1, through: 0, by: -1)
                    : stride(from: 0, through: rectWidth - 1, by: 1)
                for col in colOrder {
                    let sx = srcX + col
                    let dx = toX + col
                    guard sx >= 0, sx < width, dx >= 0, dx < width else { continue }
                    buffer[dy * width + dx] = buffer[sy * width + sx]
                }
            }
        }
    }

    /// A `Sendable` copy for hand-off to the UI/render layer.
    public func snapshot() -> VNCFrameSnapshot {
        VNCFrameSnapshot(
            width: width,
            height: height,
            pixels: pixels.withUnsafeBytes { Data($0) }
        )
    }
}

/// An immutable, `Sendable` snapshot of the framebuffer for the render layer.
public struct VNCFrameSnapshot: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// BGRX bytes, `width * height * 4` long.
    public let pixels: Data

    public init(width: Int, height: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}
