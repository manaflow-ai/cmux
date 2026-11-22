import CoreGraphics
import CoreVideo
import Foundation

/// Paints a synthetic desktop into an NV12 buffer: a dark backdrop, three
/// window-like panels with title bars and text lines, a bright square at
/// the pointer, and the frame counter marker. Luma and chroma only; no
/// Core Graphics, so it runs on any thread with no window server.
nonisolated enum SyntheticFramePainter {
    struct Scene: Sendable, Equatable {
        var counter: UInt16
        /// Pointer position in frame pixels.
        var pointer: CGPoint
    }

    static func paint(_ scene: Scene, into buffer: CVPixelBuffer) {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let y = Plane(base: yBase.assumingMemoryBound(to: UInt8.self), stride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                      width: width, height: height)
        let uv = Plane(base: uvBase.assumingMemoryBound(to: UInt8.self), stride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1),
                       width: width, height: height / 2)
        // Backdrop: a slight vertical gradient, neutral chroma.
        for row in 0..<height {
            (y.base + row * y.stride).update(repeating: UInt8(34 + 18 * row / max(height, 1)), count: width)
        }
        for row in 0..<(height / 2) {
            (uv.base + row * uv.stride).update(repeating: 128, count: width)
        }
        let panels: [(CGRect, UInt8, (UInt8, UInt8))] = [
            (CGRect(x: 0.08, y: 0.16, width: 0.46, height: 0.52), 214, (128, 128)),
            (CGRect(x: 0.40, y: 0.32, width: 0.50, height: 0.56), 70, (140, 118)),
            (CGRect(x: 0.62, y: 0.10, width: 0.30, height: 0.26), 180, (118, 134)),
        ]
        for (unit, luma, chroma) in panels {
            let rect = CGRect(
                x: unit.minX * CGFloat(width), y: unit.minY * CGFloat(height),
                width: unit.width * CGFloat(width), height: unit.height * CGFloat(height)).integral
            fill(rect, luma: luma, chroma: chroma, y: y, uv: uv)
            fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 28), luma: luma &- 40, chroma: chroma, y: y, uv: uv)
            var line = rect.minY + 48
            while line + 6 < rect.maxY - 12 {
                let length = rect.width * (0.35 + 0.5 * CGFloat(Int(line) % 7) / 7)
                fill(CGRect(x: rect.minX + 16, y: line, width: length, height: 6), luma: luma > 128 ? 60 : 200,
                     chroma: (128, 128), y: y, uv: uv)
                line += 16
            }
        }
        let pointer = CGRect(x: scene.pointer.x - 12, y: scene.pointer.y - 12, width: 24, height: 24).integral
        fill(pointer, luma: 235, chroma: (110, 150), y: y, uv: uv)
        fill(CGRect(x: 0, y: 0, width: RemoteFrameMarker.cell * RemoteFrameMarker.totalCells, height: RemoteFrameMarker.cell),
             luma: 0, chroma: (128, 128), y: y, uv: uv)
        if width >= RemoteFrameMarker.cell * RemoteFrameMarker.totalCells, height >= RemoteFrameMarker.cell {
            RemoteFrameMarker.draw(scene.counter, y: y.base, yStride: y.stride)
        }
    }

    private struct Plane {
        let base: UnsafeMutablePointer<UInt8>
        let stride: Int
        /// Luma pixels per row (chroma rows hold the same number of bytes).
        let width: Int
        let height: Int
    }

    /// Fills `rect` (clipped to the plane) with one luma and one chroma pair.
    private static func fill(_ rect: CGRect, luma: UInt8, chroma: (UInt8, UInt8), y: Plane, uv: Plane) {
        let x0 = max(Int(rect.minX), 0) & ~1
        let y0 = max(Int(rect.minY), 0) & ~1
        let x1 = min(Int(rect.maxX), y.width) & ~1
        let y1 = min(Int(rect.maxY), y.height) & ~1
        guard x1 > x0, y1 > y0 else { return }
        for row in y0..<y1 {
            (y.base + row * y.stride + x0).update(repeating: luma, count: x1 - x0)
        }
        for row in (y0 / 2)..<(y1 / 2) {
            let line = uv.base + row * uv.stride
            for column in stride(from: x0, to: x1, by: 2) {
                line[column] = chroma.0
                line[column + 1] = chroma.1
            }
        }
    }
}
