#if DEBUG || CMUX_BENCH_HOOKS
public import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One downscaled RGBA frame of a window as the window server composited it, top row first,
/// `milliseconds` after its recording started: the pixel half of the app's
/// `debug.new_tab {action: "frame_strip"}` (DEBUG builds), each frame compared with the one before
/// a key and the last.
public nonisolated struct WindowFrame: Sendable {
    public var milliseconds: Double
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    /// One frame's comparisons with the frame before the key and the last one.
    public nonisolated struct Measure: Sendable {
        public var outsideBefore: Double, outsideFinal: Double, insideBefore: Double, insideFinal: Double
        public var stripBefore: Double, stripFinal: Double, flatness: Double
    }

    @concurrent public static func measure(_ frames: [WindowFrame], before: WindowFrame, last: WindowFrame,
                                          content: CGRect?, strip: CGRect?) async -> [Measure] {
        let outside = content.map { content in strip.map { content.union($0) } ?? content }
        return frames.map { frame in
            // Outside: the window beyond the content and the strip, whose tabs slide on their own.
            Measure(outsideBefore: frame.difference(from: before, excluding: outside),
                    outsideFinal: frame.difference(from: last, excluding: outside),
                    insideBefore: content.map { frame.difference(from: before, excluding: strip, within: $0) } ?? 0,
                    insideFinal: content.map { frame.difference(from: last, excluding: strip, within: $0) } ?? 0,
                    stripBefore: strip.map { frame.difference(from: before, within: $0) } ?? 0,
                    stripFinal: strip.map { frame.difference(from: last, within: $0) } ?? 0,
                    flatness: content.map { frame.flatness(in: $0) } ?? 0)
        }
    }

    /// Reads the window's composited image back to back until `until` ms after `start`. `crop`: the
    /// part to keep, as fractions of the image (top-left origin), e.g. a tab strip at full scale.
    @concurrent public static func record(_ window: CGWindowID, scale: Double, crop: CGRect? = nil, from start: ContinuousClock.Instant,
                                         until: Double) async -> [WindowFrame] {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return [] }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        var frames: [WindowFrame] = []
        // Each pass reads one image (a window server round trip); the loop ends at the deadline.
        while elapsed(since: start) < until {
            // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming | NominalResolution.
            guard let image = create(.null, 1 << 3, window, (1 << 0) | (1 << 9))?.takeRetainedValue() else { break }
            let at = elapsed(since: start)
            // A frame the crop cannot cut is dropped, so every frame of a strip has one size.
            let kept = crop.map { unit in
                image.cropping(to: CGRect(x: unit.minX * Double(image.width), y: unit.minY * Double(image.height),
                                          width: unit.width * Double(image.width), height: unit.height * Double(image.height)).integral)
            } ?? image
            if let kept, let frame = WindowFrame(kept, scale: scale, at: at) { frames.append(frame) }
        }
        return frames
    }

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
        self.milliseconds = milliseconds
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The share of pixels outside `excluded` (or only those `within` it) whose color differs by more than a small step.
    /// A channel step that counts a pixel changed: 24 missed a background in another dark color (13 apart).
    static let channelStep = 8

    func difference(from b: WindowFrame, excluding excluded: CGRect? = nil, within: CGRect? = nil) -> Double {
        guard width == b.width, height == b.height else { return 1 }
        var differing = 0, counted = 0
        for y in 0..<height {
            for x in 0..<width {
                // The bitmap holds its top row first, as the rects count from the top left.
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if let excluded, excluded.contains(point) { continue }
                if let within, !within.contains(point) { continue }
                let i = (y * width + x) * 4
                counted += 1
                if max(abs(Int(pixels[i]) - Int(b.pixels[i])), abs(Int(pixels[i + 1]) - Int(b.pixels[i + 1])),
                       abs(Int(pixels[i + 2]) - Int(b.pixels[i + 2]))) > Self.channelStep { differing += 1 }
            }
        }
        return counted == 0 ? 0 : Double(differing) / Double(counted)
    }

    /// The share of `rect`'s pixels within a small step of its most common color.
    func flatness(in rect: CGRect) -> Double {
        var counts: [UInt32: Int] = [:], total = 0
        var samples: [(Int, Int, Int)] = []
        for y in 0..<height {
            for x in 0..<width where rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
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

    static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    var image: CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func write(to path: String) {
        guard let image else { return }
        Self.writePNG(image, to: path)
    }

    /// The frames side by side, one gap apart, at their recorded size.
    public static func writeStrip(_ frames: [WindowFrame], to path: String) {
        guard let first = frames.first else { return }
        // Full-scale frames (their own PNGs) make an overview too wide to draw: it shrinks to 16k pixels.
        let gap = 4, full = frames.count * (first.width + gap) - gap
        let factor = min(1, 16_384 / Double(max(1, full)))
        let cell = Double(first.width + gap) * factor
        guard let context = CGContext(data: nil, width: Int((Double(full) * factor).rounded(.up)), height: max(1, Int((Double(first.height) * factor).rounded(.up))),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.interpolationQuality = .medium
        for (index, frame) in frames.enumerated() {
            guard let image = frame.image else { continue }
            context.draw(image, in: CGRect(x: Double(index) * cell, y: 0, width: Double(frame.width) * factor, height: Double(frame.height) * factor))
        }
        if let strip = context.makeImage() { writePNG(strip, to: path) }
    }

    static func writePNG(_ image: CGImage, to path: String) {
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
#endif
