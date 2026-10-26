import CoreGraphics
import Foundation

/// The client's copy of the remote screen: row-major `0xAARRGGBB` words
/// (bytes `B G R A` in memory, opaque). One session task owns it.
final class Framebuffer {
    private(set) var width: Int
    private(set) var height: Int
    private(set) var pixels: [UInt32]
    /// Union of rectangles written since the last `takeDirty()`.
    private var dirty: CGRect = .null

    init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        pixels = [UInt32](repeating: 0xFF00_0000, count: self.width * self.height)
    }

    /// DesktopSize: new geometry, keeping the overlapping top-left region.
    func resize(width newWidth: Int, height newHeight: Int) {
        let w = max(0, newWidth), h = max(0, newHeight)
        guard w != width || h != height else { return }
        var next = [UInt32](repeating: 0xFF00_0000, count: w * h)
        let copyWidth = min(w, width), copyHeight = min(h, height)
        for row in 0 ..< copyHeight {
            next.replaceSubrange(row * w ..< row * w + copyWidth, with: pixels[row * width ..< row * width + copyWidth])
        }
        pixels = next
        width = w
        height = h
        dirty = CGRect(x: 0, y: 0, width: w, height: h)
    }

    /// The rectangle clipped to the framebuffer; nil when empty.
    func clip(x: Int, y: Int, width w: Int, height h: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }

    func markDirty(x: Int, y: Int, width w: Int, height h: Int) {
        guard let rect = clip(x: x, y: y, width: w, height: h) else { return }
        dirty = dirty.union(CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h))
    }

    /// The dirty union since the last call, then clears it.
    func takeDirty() -> CGRect {
        defer { dirty = .null }
        return dirty
    }

    func fill(x: Int, y: Int, width w: Int, height h: Int, color: UInt32) {
        guard let rect = clip(x: x, y: y, width: w, height: h) else { return }
        write { pixels, stride in
            for row in rect.y ..< rect.y + rect.h {
                let start = row * stride + rect.x
                for index in start ..< start + rect.w { pixels[index] = color }
            }
        }
        markDirty(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
    }

    /// Writes `w * h` little-endian BGRX pixels (4 bytes each), forcing alpha.
    func blitBGRX(x: Int, y: Int, width w: Int, height h: Int, bytes: ArraySlice<UInt8>) {
        guard bytes.count >= w * h * 4, let rect = clip(x: x, y: y, width: w, height: h) else { return }
        write { pixels, stride in
            for row in rect.y ..< rect.y + rect.h {
                var source = bytes.startIndex + ((row - y) * w + (rect.x - x)) * 4
                var target = row * stride + rect.x
                for _ in 0 ..< rect.w {
                    pixels[target] = UInt32(bytes[source]) | UInt32(bytes[source + 1]) << 8
                        | UInt32(bytes[source + 2]) << 16 | 0xFF00_0000
                    source += 4
                    target += 1
                }
            }
        }
        markDirty(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
    }

    /// Writes `w * h` already-opaque pixels.
    func blit(x: Int, y: Int, width w: Int, height h: Int, pixels source: ArraySlice<UInt32>) {
        guard source.count >= w * h, let rect = clip(x: x, y: y, width: w, height: h) else { return }
        write { pixels, stride in
            for row in rect.y ..< rect.y + rect.h {
                let from = source.startIndex + (row - y) * w + (rect.x - x), to = row * stride + rect.x
                for column in 0 ..< rect.w { pixels[to + column] = source[from + column] }
            }
        }
        markDirty(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
    }

    /// CopyRect: overlapping moves are safe (row order follows the direction).
    func copy(fromX: Int, fromY: Int, toX: Int, toY: Int, width w: Int, height h: Int) {
        guard let source = clip(x: fromX, y: fromY, width: w, height: h),
              source.w == w, source.h == h,
              let target = clip(x: toX, y: toY, width: w, height: h), target.w == w, target.h == h else { return }
        let rows: [Int] = toY > fromY ? Array((0 ..< h).reversed()) : Array(0 ..< h)
        write { pixels, stride in
            for row in rows {
                let from = (fromY + row) * stride + fromX, to = (toY + row) * stride + toX
                // Within one row the ranges overlap only when moving sideways: copy from the far end
                // when moving right, as memmove does, so no word is read after it was overwritten.
                if to > from {
                    for column in (0 ..< w).reversed() { pixels[to + column] = pixels[from + column] }
                } else {
                    for column in 0 ..< w { pixels[to + column] = pixels[from + column] }
                }
            }
        }
        markDirty(x: toX, y: toY, width: w, height: h)
    }

    /// One exclusive access to the pixel words for a whole write, with the row stride: checked
    /// indexing on a local array instead of pointer arithmetic, and no per-word access of the
    /// stored property.
    private func write(_ body: (inout [UInt32], _ stride: Int) -> Void) {
        body(&pixels, width)
    }
}
