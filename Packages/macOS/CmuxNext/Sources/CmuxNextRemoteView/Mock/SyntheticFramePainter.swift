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
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        var y = SyntheticPlane(width: width, height: height)
        // Chroma rows hold `width` bytes: one interleaved U, V pair per two pixels.
        var uv = SyntheticPlane(width: width, height: height / 2)
        // Backdrop: a slight vertical gradient, neutral chroma.
        for row in 0..<height {
            y.fill(row: row, count: width, with: UInt8(34 + 18 * row / max(height, 1)))
        }
        for row in 0..<(height / 2) {
            uv.fill(row: row, count: width, with: 128)
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
            fill(rect, luma: luma, chroma: chroma, y: &y, uv: &uv)
            fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 28), luma: luma &- 40, chroma: chroma, y: &y, uv: &uv)
            var line = rect.minY + 48
            while line + 6 < rect.maxY - 12 {
                let length = rect.width * (0.35 + 0.5 * CGFloat(Int(line) % 7) / 7)
                fill(CGRect(x: rect.minX + 16, y: line, width: length, height: 6), luma: luma > 128 ? 60 : 200,
                     chroma: (128, 128), y: &y, uv: &uv)
                line += 16
            }
        }
        let pointer = CGRect(x: scene.pointer.x - 12, y: scene.pointer.y - 12, width: 24, height: 24).integral
        fill(pointer, luma: 235, chroma: (110, 150), y: &y, uv: &uv)
        fill(CGRect(x: 0, y: 0, width: RemoteFrameMarker.cell * RemoteFrameMarker.totalCells, height: RemoteFrameMarker.cell),
             luma: 0, chroma: (128, 128), y: &y, uv: &uv)
        if width >= RemoteFrameMarker.cell * RemoteFrameMarker.totalCells, height >= RemoteFrameMarker.cell {
            RemoteFrameMarker.draw(scene.counter, into: &y)
        }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        y.copy(into: buffer, plane: 0)
        uv.copy(into: buffer, plane: 1)
    }

    /// Fills `rect` (clipped to the plane) with one luma and one chroma pair.
    private static func fill(
        _ rect: CGRect, luma: UInt8, chroma: (UInt8, UInt8), y: inout SyntheticPlane, uv: inout SyntheticPlane
    ) {
        let x0 = max(Int(rect.minX), 0) & ~1
        let y0 = max(Int(rect.minY), 0) & ~1
        let x1 = min(Int(rect.maxX), y.width) & ~1
        let y1 = min(Int(rect.maxY), y.height) & ~1
        guard x1 > x0, y1 > y0 else { return }
        for row in y0..<y1 {
            y.fill(row: row, column: x0, count: x1 - x0, with: luma)
        }
        for row in (y0 / 2)..<(y1 / 2) {
            for column in stride(from: x0, to: x1, by: 2) {
                uv[row, column] = chroma.0
                uv[row, column + 1] = chroma.1
            }
        }
    }
}

/// One plane of a synthetic frame, painted in Swift memory (every write
/// bounds checked) and copied into the pixel buffer once per frame, so the
/// painter holds no pointer into the buffer.
nonisolated struct SyntheticPlane {
    /// Bytes per row.
    let width: Int
    let height: Int
    private(set) var bytes: [UInt8]

    init(width: Int, height: Int) {
        self.width = max(width, 0)
        self.height = max(height, 0)
        bytes = [UInt8](repeating: 0, count: self.width * self.height)
    }

    /// Sets `count` bytes of `row`, from `column` on, to `value`.
    mutating func fill(row: Int, column: Int = 0, count: Int, with value: UInt8) {
        let start = row * width + column
        bytes.replaceSubrange(start..<(start + count), with: repeatElement(value, count: count))
    }

    subscript(row: Int, column: Int) -> UInt8 {
        get { bytes[row * width + column] }
        set { bytes[row * width + column] = newValue }
    }

    /// Copies the rows into `plane` of `buffer`, whose base address the
    /// caller has locked: as many rows, and bytes per row, as both hold.
    func copy(into buffer: CVPixelBuffer, plane: Int) {
        // SAFETY: the caller locked the buffer, so the plane's base address stays valid
        // until it unlocks, after this function returns.
        guard let destination = unsafe CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let rows = min(height, CVPixelBufferGetHeightOfPlane(buffer, plane))
        let rowBytes = min(width, stride)
        bytes.withUnsafeBytes { source in
            // SAFETY: source views `bytes`, live for this closure.
            guard let start = unsafe source.baseAddress else { return }
            for row in 0..<rows {
                // SAFETY: row < the plane's height and rowBytes <= its stride, so the write stays in
                // its height * stride bytes; row < height and rowBytes <= width, so the read stays
                // in the width * height bytes of `bytes`.
                unsafe (destination + row * stride).copyMemory(from: start + row * width, byteCount: rowBytes)
            }
        }
    }
}
