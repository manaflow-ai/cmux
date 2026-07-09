#if DEBUG
import Foundation

/// A statistical fingerprint of one IOSurface-backed terminal frame, used by
/// the debug socket to detect transient blank frames without Screen Recording
/// permissions.
///
/// The live IOSurface lock, layer-class/gravity reads, and crop-to-pixel
/// clamping stay app-side on the main actor (they touch QuartzCore and the
/// private `IOSurfaceLayer`); the app hands the locked pixel buffer plus the
/// already-clamped sampling bounds to
/// ``analyze(base:bytesPerRow:x0:y0:x1:y1:iosurfaceWidthPx:iosurfaceHeightPx:expectedWidthPx:expectedHeightPx:layerClass:layerContentsGravity:layerContentsKey:)``,
/// which runs the pure pixel-statistics core: a 12-bit-quantized (4 bits per RGB
/// channel) color histogram with mode fraction, BT.709 luma mean/standard
/// deviation, and an FNV-1a fingerprint over the per-pixel quantized luma.
public struct DebugFrameSample {
    /// The number of pixels sampled, after the stride-6 subsampling.
    public let sampleCount: Int
    /// The count of distinct 12-bit-quantized colors among the sampled pixels.
    public let uniqueQuantized: Int
    /// The standard deviation of the BT.709 luma over the sampled pixels.
    public let lumaStdDev: Double
    /// The fraction of sampled pixels belonging to the most common quantized color.
    public let modeFraction: Double
    /// An FNV-1a hash over the per-pixel quantized luma, identifying the frame.
    public let fingerprint: UInt64
    /// The sampled IOSurface width in pixels (`0` when unavailable).
    public let iosurfaceWidthPx: Int
    /// The sampled IOSurface height in pixels (`0` when unavailable).
    public let iosurfaceHeightPx: Int
    /// The expected layer width in pixels, from `bounds.width * contentsScale`.
    public let expectedWidthPx: Int
    /// The expected layer height in pixels, from `bounds.height * contentsScale`.
    public let expectedHeightPx: Int
    /// The sampled layer's concrete class name.
    public let layerClass: String
    /// The sampled layer's `contentsGravity` raw value.
    public let layerContentsGravity: String
    /// The sampled layer's contents identity key.
    public let layerContentsKey: String

    /// Creates a debug frame sample from already-computed statistics.
    ///
    /// The app constructs this directly for the no-contents and
    /// non-IOSurface-contents short circuits; the pixel-statistics path goes
    /// through ``analyze(base:bytesPerRow:x0:y0:x1:y1:iosurfaceWidthPx:iosurfaceHeightPx:expectedWidthPx:expectedHeightPx:layerClass:layerContentsGravity:layerContentsKey:)``.
    public init(
        sampleCount: Int,
        uniqueQuantized: Int,
        lumaStdDev: Double,
        modeFraction: Double,
        fingerprint: UInt64,
        iosurfaceWidthPx: Int,
        iosurfaceHeightPx: Int,
        expectedWidthPx: Int,
        expectedHeightPx: Int,
        layerClass: String,
        layerContentsGravity: String,
        layerContentsKey: String
    ) {
        self.sampleCount = sampleCount
        self.uniqueQuantized = uniqueQuantized
        self.lumaStdDev = lumaStdDev
        self.modeFraction = modeFraction
        self.fingerprint = fingerprint
        self.iosurfaceWidthPx = iosurfaceWidthPx
        self.iosurfaceHeightPx = iosurfaceHeightPx
        self.expectedWidthPx = expectedWidthPx
        self.expectedHeightPx = expectedHeightPx
        self.layerClass = layerClass
        self.layerContentsGravity = layerContentsGravity
        self.layerContentsKey = layerContentsKey
    }

    /// Whether the sampled contents are probably a blank frame.
    ///
    /// True when luma variation is tiny and one color dominates, or when very
    /// few quantized colors are present and one still dominates.
    public var isProbablyBlank: Bool {
        (lumaStdDev < 3.5 && modeFraction > 0.985) ||
        (uniqueQuantized <= 6 && modeFraction > 0.95)
    }

    /// Runs the pure pixel-statistics core over a locked IOSurface buffer.
    ///
    /// The caller must hold the IOSurface lock for the duration of the call and
    /// pass the base address, row stride, and the already-clamped pixel sampling
    /// bounds `[x0, x1)` by `[y0, y1)`. Pixels are subsampled with a stride of 6
    /// and assumed to be 4-byte BGRA. Returns `nil` when no pixel is sampled (an
    /// empty bound), matching the legacy short circuit.
    public static func analyze(
        base: UnsafeRawPointer,
        bytesPerRow: Int,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int,
        iosurfaceWidthPx: Int,
        iosurfaceHeightPx: Int,
        expectedWidthPx: Int,
        expectedHeightPx: Int,
        layerClass: String,
        layerContentsGravity: String,
        layerContentsKey: String
    ) -> DebugFrameSample? {
        // Assume 4 bytes/pixel BGRA (common for IOSurfaceLayer contents).
        let bytesPerPixel = 4
        let step = 6

        var hist = [UInt16: Int]()
        hist.reserveCapacity(256)

        var lumas = [Double]()
        lumas.reserveCapacity(((x1 - x0) / step) * ((y1 - y0) / step))

        var count = 0
        var fnv: UInt64 = 1469598103934665603

        for y in stride(from: y0, to: y1, by: step) {
            let row = base.advanced(by: y * bytesPerRow)
            for x in stride(from: x0, to: x1, by: step) {
                let p = row.advanced(by: x * bytesPerPixel)
                let b = Double(p.load(fromByteOffset: 0, as: UInt8.self))
                let g = Double(p.load(fromByteOffset: 1, as: UInt8.self))
                let r = Double(p.load(fromByteOffset: 2, as: UInt8.self))
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                lumas.append(luma)

                let rq = UInt16(UInt8(r) >> 4)
                let gq = UInt16(UInt8(g) >> 4)
                let bq = UInt16(UInt8(b) >> 4)
                let key = (rq << 8) | (gq << 4) | bq
                hist[key, default: 0] += 1
                count += 1

                let lq = UInt8(max(0, min(63, Int(luma / 4.0))))
                fnv ^= UInt64(lq)
                fnv &*= 1099511628211
            }
        }

        guard count > 0 else { return nil }
        let mean = lumas.reduce(0.0, +) / Double(lumas.count)
        let variance = lumas.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lumas.count)
        let stddev = sqrt(variance)

        let modeCount = hist.values.max() ?? 0
        let modeFrac = Double(modeCount) / Double(count)

        return DebugFrameSample(
            sampleCount: count,
            uniqueQuantized: hist.count,
            lumaStdDev: stddev,
            modeFraction: modeFrac,
            fingerprint: fnv,
            iosurfaceWidthPx: iosurfaceWidthPx,
            iosurfaceHeightPx: iosurfaceHeightPx,
            expectedWidthPx: expectedWidthPx,
            expectedHeightPx: expectedHeightPx,
            layerClass: layerClass,
            layerContentsGravity: layerContentsGravity,
            layerContentsKey: layerContentsKey
        )
    }
}
#endif
