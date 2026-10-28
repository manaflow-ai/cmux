#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextCompat
import ImageIO
import UniformTypeIdentifiers

/// The frames of one `debug.window_record` recording (DEBUG): for each frame, the window server's image of a
/// ``WindowCapturePlan`` as `DIR/frame-NNNNN.jpg`, then `DIR/frames.json` with each frame's `times` (seconds since
/// the first), `luminance` (mean Rec. 709 luminance, 0...1) and `peak` (the brightest of its 64 cells).
///
/// The capture waits for the window server, so it runs with the encode on the recording's own serial queue, never
/// on the main thread, whose display-link tick only reads the plan. The queue keeps the frames in order, and
/// ``finish()``, queued last, sees all of them. A frame that finds ``queuedLimit`` frames still queued is dropped,
/// so a slow window server never backs the queue up.
public nonisolated final class WindowRecording: Sendable {
    private struct Series: Sendable {
        var times: [Double] = []
        var means: [Double] = []
        var peaks: [Double] = []
        /// Frames queued and not yet run.
        var queued = 0
    }

    /// The most frames waiting on the queue.
    public static let queuedLimit = 2

    /// The folder the frames go to.
    public let dir: URL
    private let queue = DispatchQueue(label: "debug.window_record", qos: .userInitiated)
    // concurrency-allow: a short non-blocking critical section over the frame series, taken by the main thread's tick and the recording queue (lock carve-out).
    private let series = Mutex(Series())

    public init(dir: URL) {
        self.dir = dir
    }

    /// Queues the frame `plan` names, taken `time` seconds after the first; false when it is dropped.
    @discardableResult
    public func record(_ plan: WindowCapturePlan, at time: Double) -> Bool {
        let taken = series.withLock { series -> Bool in
            guard series.queued < Self.queuedLimit else { return false }
            series.queued += 1
            return true
        }
        guard taken else { return false }
        queue.async { [self] in
            defer { series.withLock { $0.queued -= 1 } }
            guard let image = NSWindow.capture(plan) else { return }
            let reading = Self.brightness(of: image)
            let index = series.withLock { series -> Int in
                series.times.append(time)
                series.means.append(reading.mean)
                series.peaks.append(reading.peak)
                return series.times.count - 1
            }
            let url = dir.appendingPathComponent(String(format: "frame-%05d.jpg", index))
            guard let dest = blockingImageDestination(url: url as CFURL, type: UTType.jpeg.identifier as CFString, count: 1) else { return }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            _ = blockingImageDestinationFinalize(dest)
        }
        return true
    }

    /// Writes `frames.json` once every frame queued before it ran.
    public func finish() {
        queue.async { [self] in
            let frames = series.withLock { series -> [String: [Double]] in
                ["times": series.times, "luminance": series.means, "peak": series.peaks]
            }
            if let data = try? JSONSerialization.data(withJSONObject: frames) {
                try? data.blockingWrite(to: dir.appendingPathComponent("frames.json"))
            }
        }
    }

    /// How bright `image` is: `mean`, its mean Rec. 709 luminance, and
    /// `peak`, the brightest of its 64 cells, so a white flash over part
    /// of the window shows even when the mean stays low. Core Graphics
    /// resamples the frame down to 8x8, which averages every pixel into a
    /// cell. Both are 0...1, and 0 when the draw fails.
    static func brightness(of image: CGImage) -> (mean: Double, peak: Double) {
        let side = 8
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let pixels = DrawnPixels(width: side, height: side, bytesPerPixel: 4, space: space,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue, draw: { context in
                  context.interpolationQuality = .high
                  context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
              })?.bytes else { return (0, 0) }
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
