import CoreGraphics
import Foundation

/// How far one capture of a glass surface is from another, pixel by pixel: the Liquid Glass Parity
/// playground's native surface against the web UI's same surface over the same backdrop
/// (``GlassParityPlayground``). Pure: two RGBA8 buffers of one size in, numbers out, so the test pins
/// the arithmetic and the capture only supplies pixels.
///
/// Each pixel's error is the largest of its three color channels' absolute differences, 0...255
/// (alpha is not compared: both captures are of opaque window pixels). `excluded` boxes (the text,
/// whose glyph rasterization differs between AppKit and the web engines for reasons that are not the
/// material) are left out when asked.
nonisolated struct GlassParityDiff: Equatable, Sendable {
    /// The mean per-pixel error.
    var mean: Double
    /// The 95th and 99th percentile per-pixel error.
    var p95: Int
    var p99: Int
    /// The largest per-pixel error.
    var max: Int
    /// The share of pixels whose error is above ``visibleStep`` (0...1): where a person could see a
    /// difference side by side.
    var visible: Double
    /// The pixels compared.
    var pixels: Int

    /// A channel step a person can tell apart on a glass surface side by side, out of 255 (about 3%).
    static let visibleStep = 8

    /// The tolerance a drawn surface must stay within (``GlassParityPlayground``'s `measure` and
    /// scripts/cmux-next/glass-parity-shots.py fail past it): the material path that draws the App's own
    /// glass under the page (host glass) must match the native surface beside it to within a mean
    /// error of 1 and a 99th percentile of ``visibleStep``, text excluded.
    static let hostTolerance = Tolerance(mean: 1.0, p99: visibleStep)

    struct Tolerance: Equatable, Sendable {
        var mean: Double
        var p99: Int
    }

    /// Whether these numbers are within `tolerance`.
    func within(_ tolerance: Tolerance) -> Bool { mean <= tolerance.mean && p99 <= tolerance.p99 }

    /// Compares `a` and `b`, RGBA8 rows of `width` by `height` pixels with `bytesPerRow` bytes each,
    /// leaving out the pixels inside `excluded` (pixel boxes, top-left origin). Nil when the buffers
    /// are too small for the size or nothing is left to compare.
    static func compare(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, bytesPerRow: Int,
                        excluded: [CGRect] = []) -> GlassParityDiff? {
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              a.count >= bytesPerRow * height, b.count >= bytesPerRow * height else { return nil }
        let boxes = excluded.map { $0.integral }
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        var sum = 0
        var worst = 0
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                if !boxes.isEmpty, boxes.contains(where: { $0.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) }) {
                    continue
                }
                let i = row + x * 4
                let error = Swift.max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])),
                                      abs(Int(a[i + 2]) - Int(b[i + 2])))
                histogram[error] += 1
                sum += error
                total += 1
                if error > worst { worst = error }
            }
        }
        guard total > 0 else { return nil }
        func percentile(_ share: Double) -> Int {
            let rank = Int((Double(total) * share).rounded(.up))
            var seen = 0
            for (error, count) in histogram.enumerated() {
                seen += count
                if seen >= rank { return error }
            }
            return worst
        }
        let visible = histogram[(visibleStep + 1)...].reduce(0, +)
        return GlassParityDiff(mean: Double(sum) / Double(total), p95: percentile(0.95), p99: percentile(0.99),
                               max: worst, visible: Double(visible) / Double(total), pixels: total)
    }

    /// The RGBA8 pixels of `image` inside `rect` (pixel box, top-left origin) in sRGB, with the row
    /// length: what ``compare(_:_:width:height:bytesPerRow:excluded:)`` reads.
    static func pixels(of image: CGImage, in rect: CGRect) -> (bytes: [UInt8], width: Int, height: Int)? {
        let box = rect.integral
        guard let crop = image.cropping(to: box), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (bytes, width, height) : nil
    }

    /// The numbers as the debug verb and the capture script report them.
    var json: [String: Double] {
        ["mean": (mean * 1000).rounded() / 1000, "p95": Double(p95), "p99": Double(p99), "max": Double(max),
         "visible": (visible * 10000).rounded() / 10000, "pixels": Double(pixels)]
    }
}
