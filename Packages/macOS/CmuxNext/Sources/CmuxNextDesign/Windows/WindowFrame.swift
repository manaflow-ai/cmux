#if DEBUG || CMUX_BENCH_HOOKS
public import CoreGraphics
import CmuxNextCompat
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
        /// The content area's ink before the key or at the end, whichever is more (``PaneMeasure/settledInk``).
        public var settledInk: Double = 0
        /// Each of `measure`'s `panes`, in its order.
        public var panes: [PaneMeasure] = []
    }

    /// One pane's content area in one frame: how flat it is and, when flat, how far it is from the same rect in the
    /// frame before the key and in the last frame (0 for a rect that is not flat: it cannot be blank, so it is not compared).
    /// `settledInk`: the share of the rect off its one color (1 - flatness) before the key or at the end, whichever is more.
    public nonisolated struct PaneMeasure: Sendable, Equatable {
        public var flatness: Double, vsBefore: Double, vsFinal: Double, settledInk: Double

        public init(flatness: Double, vsBefore: Double, vsFinal: Double, settledInk: Double) {
            (self.flatness, self.vsBefore, self.vsFinal, self.settledInk) = (flatness, vsBefore, vsFinal, settledInk)
        }

        /// The flatness past which a content area counts as one color: an empty terminal is flat too, so a blank
        /// frame must also differ from both the frame before the key and the last one.
        public static let flatShare = 0.995

        /// Blank: one flat color that is neither what the rect showed before the key nor what it settles on, and that
        /// lost its ink (at most half of what the rect held before or at the end) or changed color. An empty terminal is flat even with its
        /// prompt drawn, and mid-motion that prompt sits where neither frame has it; it still has its ink, so it is drawn.
        public func isBlank(tolerance: Double) -> Bool {
            Self.isBlank(flatness: flatness, vsBefore: vsBefore, vsFinal: vsFinal, settledInk: settledInk, tolerance: tolerance)
        }

        public static func isBlank(flatness: Double, vsBefore: Double, vsFinal: Double, settledInk: Double, tolerance: Double) -> Bool {
            guard flatness > flatShare, vsBefore > tolerance, vsFinal > tolerance else { return false }
            // A pane that changed color (a flash of another background) is blank with its ink or without it.
            return (1 - flatness) * 2 <= settledInk || min(vsBefore, vsFinal) > recolored
        }

        /// The share of a flat rect that differs from both frames past which its color changed, not just its ink moved:
        /// a moving prompt differs by a few percent at most, a flash of another background by nearly all of it.
        public static let recolored = 0.25
    }

    /// The pane rects a frame strip judges for blank frames: `before` (at the key) then `final` (at the report), as
    /// whole pixels, empty and repeated rects dropped, at most `cap` (the panes on screen; a cap bounds the work).
    public static func paneRects(before: [CGRect], final: [CGRect], cap: Int = 16) -> [CGRect] {
        var rects: [CGRect] = []
        for rect in before + final {
            let whole = rect.integral
            guard rects.count < cap, !whole.isNull, whole.width >= 1, whole.height >= 1, !rects.contains(whole) else { continue }
            rects.append(whole)
        }
        return rects
    }

    @concurrent public static func measure(_ frames: [WindowFrame], before: WindowFrame, last: WindowFrame,
                                          content: CGRect?, strip: CGRect?, panes: [CGRect] = []) async -> [Measure] {
        let outside = content.map { content in strip.map { content.union($0) } ?? content }
        // Read once a strip: before and last are the same for every frame.
        let contentInk = content.map { settledInk(in: $0, before: before, last: last) } ?? 0
        let paneInks = panes.map { settledInk(in: $0, before: before, last: last) }
        return frames.map { frame in
            var measure = measured(frame, before: before, last: last, content: content, strip: strip, outside: outside)
            measure.settledInk = contentInk
            measure.panes = zip(panes, paneInks).map { frame.paneMeasure(in: $0, before: before, last: last, settledInk: $1) }
            return measure
        }
    }

    static func settledInk(in rect: CGRect, before: WindowFrame, last: WindowFrame) -> Double {
        max(1 - before.flatness(in: rect), 1 - last.flatness(in: rect))
    }

    /// One pane rect of this frame against `before` and `last`; the two comparisons only when the rect is flat.
    func paneMeasure(in rect: CGRect, before: WindowFrame, last: WindowFrame, settledInk: Double) -> PaneMeasure {
        let flat = flatness(in: rect)
        guard flat > PaneMeasure.flatShare else { return PaneMeasure(flatness: flat, vsBefore: 0, vsFinal: 0, settledInk: settledInk) }
        return PaneMeasure(flatness: flat, vsBefore: difference(from: before, within: rect), vsFinal: difference(from: last, within: rect),
                           settledInk: settledInk)
    }

    private static func measured(_ frame: WindowFrame, before: WindowFrame, last: WindowFrame, content: CGRect?, strip: CGRect?,
                                 outside: CGRect?) -> Measure {
        // Outside: the window beyond the content and the strip, whose tabs slide on their own.
        Measure(outsideBefore: frame.difference(from: before, excluding: outside),
                outsideFinal: frame.difference(from: last, excluding: outside),
                insideBefore: content.map { frame.difference(from: before, excluding: strip, within: $0) } ?? 0,
                insideFinal: content.map { frame.difference(from: last, excluding: strip, within: $0) } ?? 0,
                stripBefore: strip.map { frame.difference(from: before, within: $0) } ?? 0,
                stripFinal: strip.map { frame.difference(from: last, within: $0) } ?? 0,
                flatness: content.map { frame.flatness(in: $0) } ?? 0)
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

    /// A frame of these RGBA pixels (top row first), for tests.
    init(milliseconds: Double, width: Int, height: Int, pixels: [UInt8]) {
        (self.milliseconds, self.width, self.height, self.pixels) = (milliseconds, width, height, pixels)
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
        let (rows, columns) = within.map { span(of: $0) } ?? (rows: 0..<height, columns: 0..<width)
        for y in rows {
            for x in columns {
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
        let (rows, columns) = span(of: rect)
        for y in rows {
            for x in columns where rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
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

    /// The rows and columns that can hold a pixel center inside `rect`: a pane's rect is read alone, not the whole frame.
    func span(of rect: CGRect) -> (rows: Range<Int>, columns: Range<Int>) {
        guard !rect.isNull, rect.minX.isFinite, rect.maxX.isFinite, rect.minY.isFinite, rect.maxY.isFinite else { return (0..<0, 0..<0) }
        func range(_ low: CGFloat, _ high: CGFloat, _ limit: Int) -> Range<Int> {
            let start = min(limit, max(0, Int(low.rounded(.down)))), end = max(start, min(limit, Int(high.rounded(.up))))
            return start..<end
        }
        return (range(rect.minY, rect.maxY, height), range(rect.minX, rect.maxX, width))
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

    /// Makes `dir`, then writes each frame to its path and the strip of `strip` to `stripPath`, off the main actor: PNG
    /// encoding and file writes held it for seconds a frame strip under load, which the frame and hang probes counted.
    @concurrent public static func writeAll(_ frames: [(frame: WindowFrame, path: String)], strip: [WindowFrame], stripPath: String,
                                           in dir: String) async {
        try? FileManager.checked.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (frame, path) in frames { if let image = frame.image { writePNG(image, to: path) } }
        writeStrip(strip, to: stripPath)
    }

    static func writePNG(_ image: CGImage, to path: String) {
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// A window and every window over it in its rect (its pages and the overlay panel that carries
/// dialogs), as the screen shows them: `CmuxDialogCenter.frameStrip` (DEBUG builds) needs the
/// dialog, which draws in the overlay panel, the pages and the window under it in one frame.
nonisolated extension WindowFrame {
    /// Reads `window` and every window above it, composited in `bounds` (global display
    /// coordinates, top-left origin), back to back until `until` ms after `start`. Every frame has
    /// the size of `bounds`, so frames before and after the overlay panel attaches compare pixel for
    /// pixel. Another app's window over that rect would show too: record where none is.
    @concurrent public static func recordAbove(_ window: CGWindowID, bounds: CGRect, scale: Double,
                                              from start: ContinuousClock.Instant, until: Double) async -> [WindowFrame] {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return [] }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        var frames: [WindowFrame] = []
        while elapsed(since: start) < until {
            // kCGWindowListOptionOnScreenAboveWindow | IncludingWindow; BoundsIgnoreFraming | NominalResolution.
            guard let image = create(bounds, (1 << 1) | (1 << 3), window, (1 << 0) | (1 << 9))?.takeRetainedValue() else { break }
            if let frame = WindowFrame(image, scale: scale, at: elapsed(since: start)) { frames.append(frame) }
        }
        return frames
    }

    /// Writes each frame as `<prefix>-NNN.png` in `dir` and returns the file names.
    public static func writeEach(_ frames: [WindowFrame], prefix: String, in dir: String) -> [String] {
        frames.enumerated().map { index, frame in
            let name = String(format: "%@-%03d.png", prefix, index)
            if let image = frame.image { writePNG(image, to: (dir as NSString).appendingPathComponent(name)) }
            return name
        }
    }

    /// The mean per-channel color distance from `other` (0...255) over the pixels `within` a rect
    /// (pixel coordinates, top-left origin) and outside `excluding`: a continuous measure of how far
    /// a fade or scale has gone, where `difference` only counts pixels past a threshold.
    public func meanDistance(from other: WindowFrame, within: CGRect? = nil, excluding: CGRect? = nil) -> Double {
        guard width == other.width, height == other.height else { return 255 }
        var total = 0, counted = 0
        for y in 0..<height {
            for x in 0..<width {
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if let within, !within.contains(point) { continue }
                if let excluding, excluding.contains(point) { continue }
                let i = (y * width + x) * 4
                total += abs(Int(pixels[i]) - Int(other.pixels[i])) + abs(Int(pixels[i + 1]) - Int(other.pixels[i + 1]))
                    + abs(Int(pixels[i + 2]) - Int(other.pixels[i + 2]))
                counted += 3
            }
        }
        return counted == 0 ? 0 : Double(total) / Double(counted)
    }
}
#endif
