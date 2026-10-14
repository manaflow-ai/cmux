#if DEBUG
public import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pixel half of the app's `debug.new_tab {action: "frame_strip"}` (DEBUG builds): a window's
/// composited image read back to back, each frame compared with the one before a key and the last.
public enum WindowFrameStrip {
    /// One downscaled RGBA frame, top row first, `milliseconds` after the recording started.
    public nonisolated struct Frame: Sendable {
        public var milliseconds: Double
        public var width: Int
        public var height: Int
        public var pixels: [UInt8]
    }

    /// One frame's comparisons with the frame before the key and the last one.
    public nonisolated struct Measure: Sendable {
        public var outsideBefore: Double, outsideFinal: Double, insideBefore: Double, insideFinal: Double
        public var stripBefore: Double, stripFinal: Double, flatness: Double
    }

    @concurrent public nonisolated static func measure(_ frames: [Frame], before: Frame, last: Frame,
                                                       content: CGRect?, strip: CGRect?) async -> [Measure] {
        let outside = content.map { content in strip.map { content.union($0) } ?? content }
        return frames.map { frame in
            // Outside: the window beyond the content and the strip, whose tabs slide on their own.
            Measure(outsideBefore: difference(frame, before, excluding: outside),
                    outsideFinal: difference(frame, last, excluding: outside),
                    insideBefore: content.map { difference(frame, before, excluding: strip, within: $0) } ?? 0,
                    insideFinal: content.map { difference(frame, last, excluding: strip, within: $0) } ?? 0,
                    stripBefore: strip.map { difference(frame, before, within: $0) } ?? 0,
                    stripFinal: strip.map { difference(frame, last, within: $0) } ?? 0,
                    flatness: content.map { flatness(frame, in: $0) } ?? 0)
        }
    }

    /// Reads the window's composited image back to back until `until` ms after `start`.
    @concurrent public nonisolated static func record(_ window: CGWindowID, scale: Double, from start: ContinuousClock.Instant,
                                                      until: Double) async -> [Frame] {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return [] }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        var frames: [Frame] = []
        // Each pass reads one image (a window server round trip); the loop ends at the deadline.
        while elapsed(since: start) < until {
            // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming | NominalResolution.
            guard let image = create(.null, 1 << 3, window, (1 << 0) | (1 << 9))?.takeRetainedValue() else { break }
            let at = elapsed(since: start)
            if let frame = downscale(image, scale: scale, at: at) { frames.append(frame) }
        }
        return frames
    }

    public nonisolated static func downscale(_ image: CGImage, scale: Double, at milliseconds: Double) -> Frame? {
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
        return drawn ? Frame(milliseconds: milliseconds, width: width, height: height, pixels: pixels) : nil
    }

    /// The share of pixels outside `excluded` (or only those `within` it) whose color differs by more than a small step.
    /// A channel step that counts a pixel changed: 24 missed a background in another dark color (13 apart).
    public nonisolated static let channelStep = 8

    public nonisolated static func difference(_ a: Frame, _ b: Frame, excluding excluded: CGRect? = nil, within: CGRect? = nil) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        var differing = 0, counted = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                // The bitmap holds its top row first, as the rects count from the top left.
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if let excluded, excluded.contains(point) { continue }
                if let within, !within.contains(point) { continue }
                let i = (y * a.width + x) * 4
                counted += 1
                if max(abs(Int(a.pixels[i]) - Int(b.pixels[i])), abs(Int(a.pixels[i + 1]) - Int(b.pixels[i + 1])),
                       abs(Int(a.pixels[i + 2]) - Int(b.pixels[i + 2]))) > channelStep { differing += 1 }
            }
        }
        return counted == 0 ? 0 : Double(differing) / Double(counted)
    }

    /// The share of `rect`'s pixels within a small step of its most common color.
    public nonisolated static func flatness(_ frame: Frame, in rect: CGRect) -> Double {
        var counts: [UInt32: Int] = [:], total = 0
        var samples: [(Int, Int, Int)] = []
        for y in 0..<frame.height {
            for x in 0..<frame.width where rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                let i = (y * frame.width + x) * 4
                let r = Int(frame.pixels[i]), g = Int(frame.pixels[i + 1]), b = Int(frame.pixels[i + 2])
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

    nonisolated static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    nonisolated static func image(_ frame: Frame) -> CGImage? {
        let data = Data(frame.pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public nonisolated static func write(_ frame: Frame, to path: String) {
        guard let image = image(frame) else { return }
        writePNG(image, to: path)
    }

    /// The frames side by side, one gap apart, at their recorded size.
    public nonisolated static func writeStrip(_ frames: [Frame], to path: String) {
        guard let first = frames.first else { return }
        let gap = 4, width = frames.count * (first.width + gap) - gap
        guard let context = CGContext(data: nil, width: width, height: first.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        for (index, frame) in frames.enumerated() {
            guard let image = image(frame) else { continue }
            context.draw(image, in: CGRect(x: index * (first.width + gap), y: 0, width: frame.width, height: frame.height))
        }
        if let strip = context.makeImage() { writePNG(strip, to: path) }
    }

    nonisolated static func writePNG(_ image: CGImage, to path: String) {
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
#endif
