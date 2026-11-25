#if DEBUG || CMUX_BENCH_HOOKS
public import CoreGraphics
import CmuxNextCompat
import Foundation

/// DEBUG ONLY. Each frame's brightness, in frame order, for CmuxNextApp's `DebugWindowRecord` (`frames.json`'s
/// `luminance`, `peak` and, with `grid`, `cells`). The recorder's `encoder` queue is serial, so the order is the
/// frames' order.
public nonisolated final class WindowFrameBrightness: Sendable {
    public nonisolated struct Series: Sendable {
        public var means: [Double] = []
        public var peaks: [Double] = []
        /// With `grid`: per frame, its 16x16 cells' luminance (0...255, row by row) as 512 hex digits.
        public var cells: [String] = []
    }

    private let samples = Mutex(Series())
    private let grid: Bool

    public init(grid: Bool = false) {
        self.grid = grid
    }

    /// What every frame measured so far, in frame order.
    /// Nonisolated, like every member here: the module's default isolation
    /// is MainActor, and the encoder queue is the only caller.
    public nonisolated var series: Series { samples.withLock { $0 } }

    public nonisolated func measure(_ image: CGImage) {
        let reading = Self.brightness(of: image)
        let cells = grid ? Self.cells(of: image) : nil
        samples.withLock {
            $0.means.append(reading.mean)
            $0.peaks.append(reading.peak)
            if let cells { $0.cells.append(cells) }
        }
    }

    /// `image` resampled to 16x16 cells, each its Rec. 709 luminance as two hex digits, row by row ("" when the
    /// draw fails). A launch bench compares frames cell by cell (scripts/cmux-next/launch_shift.py).
    public nonisolated static func cells(of image: CGImage) -> String {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return "" }
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return "" }
        var text = ""
        text.reserveCapacity(side * side * 2)
        for cell in 0..<(side * side) {
            let luminance = 0.2126 * Double(pixels[cell * 4]) + 0.7152 * Double(pixels[cell * 4 + 1]) + 0.0722 * Double(pixels[cell * 4 + 2])
            let value = Int(min(255, max(0, luminance.rounded())))
            text += String(format: "%02x", value)
        }
        return text
    }

    /// How bright `image` is: `mean`, its mean Rec. 709 luminance, and
    /// `peak`, the brightest of its 64 cells, so a white flash over part
    /// of the window shows even when the mean stays low. Core Graphics
    /// resamples the frame down to 8x8, which averages every pixel into a
    /// cell. Both are 0...1, and 0 when the draw fails.
    public nonisolated static func brightness(of image: CGImage) -> (mean: Double, peak: Double) {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return (0, 0) }
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return (0, 0) }
        var total = 0.0, peak = 0.0
        for cell in 0..<(side * side) {
            func channel(_ offset: Int) -> Double { Double(pixels[cell * 4 + offset]) / 255 }
            let luminance = 0.2126 * channel(0) + 0.7152 * channel(1) + 0.0722 * channel(2)
            total += luminance
            peak = max(peak, luminance)
        }
        return (total / Double(side * side), peak)
    }
}
#endif
