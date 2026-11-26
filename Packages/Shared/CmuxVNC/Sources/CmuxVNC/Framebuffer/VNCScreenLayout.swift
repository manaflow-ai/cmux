import CoreGraphics
import CoreVideo
import Foundation

/// Finds the physical displays inside a framebuffer when the server does not
/// say (macOS Screen Sharing sends one image for all displays and no
/// ExtendedDesktopSize). Outside every display the image is pure black, so
/// each display is a run of columns with the same void above and below it.
/// Displays of equal height side by side leave no void; a frame much wider
/// than 16:9 is then split into equal pages.
public struct VNCScreenLayout: Sendable {
    /// Narrower column runs are noise (a dark window edge), not displays.
    public var minimumScreenWidth = 320
    /// Void shorter than this is content, not the gap under a shorter display.
    public var minimumVoid = 24

    public init() {}

    /// The displays in `frame`, left to right; empty for a single display.
    public func screens(in frame: VNCFrame) -> [CGRect] {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        return screens(pixels: base.assumingMemoryBound(to: UInt32.self), width: frame.width, height: frame.height,
                       rowPixels: CVPixelBufferGetBytesPerRow(buffer) / 4)
    }

    /// BGRA words, `rowPixels` per row.
    func screens(pixels: UnsafePointer<UInt32>, width: Int, height: Int, rowPixels: Int) -> [CGRect] {
        guard width > 0, height > 0 else { return [] }
        func black(_ x: Int, _ y: Int) -> Bool { pixels[y * rowPixels + x] & 0x00FF_FFFF == 0 }
        // Per column: the black rows touching the top and the bottom edge.
        var spans: [(top: Int, bottom: Int)] = []
        spans.reserveCapacity(width)
        for x in 0 ..< width {
            var top = 0
            while top < height, black(x, top) { top += 1 }
            var bottom = 0
            if top < height { while bottom < height - top, black(x, height - 1 - bottom) { bottom += 1 } }
            spans.append((top < minimumVoid ? 0 : top, bottom < minimumVoid ? 0 : bottom))
        }
        // Runs of columns with the same span.
        var runs: [(start: Int, end: Int, top: Int, bottom: Int)] = []
        for (x, span) in spans.enumerated() {
            if let last = runs.last, last.top == span.top, last.bottom == span.bottom {
                runs[runs.count - 1].end = x + 1
            } else {
                runs.append((x, x + 1, span.top, span.bottom))
            }
        }
        // Fold runs too narrow to be a display into the wider neighbor.
        var merged: [(start: Int, end: Int, top: Int, bottom: Int)] = []
        for run in runs {
            guard let last = merged.last else {
                merged.append(run)
                continue
            }
            if run.end - run.start < minimumScreenWidth || (last.top == run.top && last.bottom == run.bottom) {
                merged[merged.count - 1].end = run.end
            } else if last.end - last.start < minimumScreenWidth {
                merged[merged.count - 1] = (last.start, run.end, run.top, run.bottom)
            } else {
                merged.append(run)
            }
            // A fold can leave two equal neighbors: join them.
            if merged.count >= 2, merged[merged.count - 2].top == merged[merged.count - 1].top,
               merged[merged.count - 2].bottom == merged[merged.count - 1].bottom {
                let tail = merged.removeLast()
                merged[merged.count - 1].end = tail.end
            }
        }
        // An all-black run is a display the server has not painted yet (its
        // first update often carries only the main display): keep it full height.
        let displays = merged
            .map { run -> CGRect in
                run.top >= height ? CGRect(x: run.start, y: 0, width: run.end - run.start, height: height)
                    : CGRect(x: run.start, y: run.top, width: run.end - run.start, height: height - run.top - run.bottom)
            }
            .filter { $0.width >= CGFloat(minimumScreenWidth) && $0.height >= 200 }
        if displays.count > 1 { return displays }
        if merged.contains(where: { $0.top > 0 || $0.bottom > 0 }) { return [] }
        // No void: equal-height displays side by side, if the frame is far wider than one.
        let pages = Int((Double(width) / Double(height) / (16.0 / 9.0)).rounded())
        guard Double(width) / Double(height) >= 2.6, pages > 1 else { return [] }
        let pageWidth = width / pages
        return (0 ..< pages).map { CGRect(x: $0 * pageWidth, y: 0, width: $0 == pages - 1 ? width - $0 * pageWidth : pageWidth, height: height) }
    }
}
