#if DEBUG
public import CoreGraphics
public import QuartzCore
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One composited window image of a frame strip (`debug.new_tab {action: "frame_strip"}`,
/// DEBUG builds): RGBA pixels, rows bottom-up, read `milliseconds` after the recording began.
public nonisolated struct FrameStripFrame: Sendable {
    public var milliseconds: Double
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(milliseconds: Double, width: Int, height: Int, pixels: [UInt8]) {
        self.milliseconds = milliseconds
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// `image` drawn at `scale` of its size.
    init?(_ image: CGImage, scale: Double, at milliseconds: Double) {
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(milliseconds: milliseconds, width: width, height: height, pixels: pixels)
    }

    /// The share of pixels outside `excluded` (or only those `within` it, top-left based rects)
    /// whose color differs from `other`'s by more than a small step.
    public func difference(from other: FrameStripFrame, excluding excluded: [CGRect] = [], within: CGRect? = nil) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        var differing = 0, counted = 0
        for y in 0..<height {
            for x in 0..<width {
                // Rows run bottom-up in the bitmap; the rects are top-left based.
                let point = CGPoint(x: Double(x) + 0.5, y: Double(height - 1 - y) + 0.5)
                if excluded.contains(where: { $0.contains(point) }) { continue }
                if let within, !within.contains(point) { continue }
                let i = (y * width + x) * 4
                counted += 1
                if max(abs(Int(pixels[i]) - Int(other.pixels[i])), abs(Int(pixels[i + 1]) - Int(other.pixels[i + 1])),
                       abs(Int(pixels[i + 2]) - Int(other.pixels[i + 2]))) > 24 { differing += 1 }
            }
        }
        return counted == 0 ? 0 : Double(differing) / Double(counted)
    }

    /// The share of `rect`'s pixels within a small step of its most common color.
    public func flatness(in rect: CGRect) -> Double {
        var counts: [UInt32: Int] = [:], total = 0
        var samples: [(Int, Int, Int)] = []
        for y in 0..<height {
            for x in 0..<width where rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(height - 1 - y) + 0.5)) {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                counts[UInt32(r >> 3) << 10 | UInt32(g >> 3) << 5 | UInt32(b >> 3), default: 0] += 1
                samples.append((r, g, b))
                total += 1
            }
        }
        guard total > 0, let mode = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
        let r = Int(mode >> 10) << 3, g = Int((mode >> 5) & 31) << 3, b = Int(mode & 31) << 3
        let near = samples.filter { abs($0.0 - r) <= 12 && abs($0.1 - g) <= 12 && abs($0.2 - b) <= 12 }.count
        return Double(near) / Double(total)
    }

    var image: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func writePNG(to path: String) {
        image.map { FrameStripFrame.write($0, to: path) }
    }

    static func write(_ image: CGImage, to path: String) {
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

extension Array where Element == FrameStripFrame {
    /// The frames side by side, one gap apart, at their recorded size.
    public func writeStrip(to path: String) {
        guard let first else { return }
        let gap = 4, width = count * (first.width + gap) - gap
        guard let context = CGContext(data: nil, width: width, height: first.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        for (index, frame) in enumerated() {
            guard let image = frame.image else { continue }
            context.draw(image, in: CGRect(x: index * (first.width + gap), y: 0, width: frame.width, height: frame.height))
        }
        if let strip = context.makeImage() { FrameStripFrame.write(strip, to: path) }
    }
}

/// Reads one window's composited image back to back (a window server round trip each).
public nonisolated struct FrameStripRecorder: Sendable {
    public let window: CGWindowID
    public let scale: Double

    public init(window: CGWindowID, scale: Double) {
        self.window = window
        self.scale = scale
    }

    /// Frames until `until` ms after `start`.
    @concurrent public func record(from start: ContinuousClock.Instant, until: Double) async -> [FrameStripFrame] {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return [] }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        func elapsed() -> Double {
            let d = ContinuousClock.now - start
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        var frames: [FrameStripFrame] = []
        while elapsed() < until {
            // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming | NominalResolution.
            guard let image = create(.null, 1 << 3, window, (1 << 0) | (1 << 9))?.takeRetainedValue() else { break }
            if let frame = FrameStripFrame(image, scale: scale, at: elapsed()) { frames.append(frame) }
        }
        return frames
    }
}

/// How one animator's `MotionTrace` travel sample (`tabs.travel`: the points its springs have
/// left to move) ran after a time. Pixel shares cannot judge a moving tab (a cell sliding over
/// its neighbours is not monotonic in pixels); its own travel is: a spring only ever closes it.
public nonisolated struct MotionTravelSummary: Sendable, Equatable {
    /// Frames with travel left (more than half a point).
    public var movingFrames = 0
    /// Frames where the travel grew after it had started to fall: a second motion inside the
    /// gesture (or a retarget away), which one motion per gesture never has.
    public var restarts = 0
    /// The most travel any frame had left.
    public var peak = 0.0

    @MainActor public init(_ name: String, after time: CFTimeInterval) {
        var previous = 0.0, falling = false
        for sample in MotionTrace.samples where sample.name == name && sample.time >= time {
            if sample.value > 0.5 { movingFrames += 1 }
            peak = Swift.max(peak, sample.value)
            if sample.value < previous - 0.5 { falling = true }
            if falling, sample.value > previous + 0.5 {
                restarts += 1
                falling = false
            }
            previous = sample.value
        }
    }
}
#endif
