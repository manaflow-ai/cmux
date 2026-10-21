#if DEBUG
import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups
import ImageIO
import UniformTypeIdentifiers

/// DEBUG ONLY. `debug.window_record` {dir, seconds (at most 12), window?}:
/// the window as the window server composited it (`compositedSnapshot`,
/// as `debug.window_snapshot`, plus the app's panels over it that are not
/// its children, such as the palette opened with no key window), once per display frame of its screen (a
/// FrameClient of the window's FrameScheduler, 120 Hz on ProMotion), as JPEG frames
/// `DIR/frame-NNNNN.jpg` plus `DIR/frames.json` (index, host time in
/// seconds since the first frame). Returns at once; the recording stops by
/// itself. For before/after motion proof of the Home tab against
/// MessagesLab's own recordings (its `--live-send`); no Screen Recording
/// permission is needed for an app's own window.
///
/// `frames.json` also carries, per frame, how bright it was: `luminance`, its
/// mean Rec. 709 luminance (0...1), and `peak`, the brightest of its 64 cells.
/// A flash test asserts that neither rises over the window at rest
/// (scripts/ci/frame-pacing/dark_load_flash.py).
@MainActor
enum DebugWindowRecord {
    private static var running: Recorder?

    static func start(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard running == nil else { return .object(["error": .string("a recording is running")]) }
        guard let window = DebugWindowSnapshot.window(params, services: services) else { return .object(["error": .string("no such window")]) }
        guard let dir = params["dir"]?.stringValue.map({ ($0 as NSString).expandingTildeInPath }) else {
            return .object(["error": .string("dir is required")])
        }
        let seconds = min(12, max(0.1, params["seconds"]?.doubleValue ?? 3))
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
            return .object(["error": .string("cannot create \(dir)")])
        }
        let recorder = Recorder(window: window, dir: URL(fileURLWithPath: dir), seconds: seconds) { running = nil }
        running = recorder
        recorder.start()
        return .object(["dir": .string(dir), "seconds": .number(seconds)])
    }

    @MainActor
    private final class Recorder {
        let window: NSWindow
        let dir: URL
        let seconds: Double
        let done: () -> Void
        private var client: FrameClient?
        private var start0: CFTimeInterval?
        private var times: [Double] = []
        private let encoder = DispatchQueue(label: "debug.window_record", qos: .userInitiated)
        /// Per-frame brightness, touched only on `encoder`.
        private let brightness = Brightness()

        init(window: NSWindow, dir: URL, seconds: Double, done: @escaping () -> Void) {
            self.window = window
            self.dir = dir
            self.seconds = seconds
            self.done = done
        }

        func start() {
            let client = FrameClient(owner: "debug.window_record", isAnimation: false, on: .forWindow(window)) { [weak self] tick in
                self?.tick(tick) ?? false
            }
            self.client = client
            client.activate()
        }

        /// One frame; false once the recording is over.
        private func tick(_ tick: FrameTick) -> Bool {
            let now = tick.timestamp
            let t0 = start0 ?? now
            start0 = t0
            guard now - t0 <= seconds else { finish(); return false }
            guard let image = window.compositedSnapshot(adding: overlayPanels()) else { return true }
            let index = times.count
            times.append(now - t0)
            let url = dir.appendingPathComponent(String(format: "frame-%05d.jpg", index))
            let brightness = brightness
            encoder.async {
                // Off the main thread, beside the encode: this is a frame of a
                // recording other scenarios read for motion proof, so the
                // display-link tick must not grow by a resample per frame. The
                // queue is serial, so the two arrays stay in frame order and
                // `finish`, queued last, sees all of them.
                brightness.measure(image)
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
            return true
        }

        /// The app's visible panels over the window that are not its children
        /// (the palette opened with no key window, hover cards), so the
        /// recording shows them as a person sees them.
        private func overlayPanels() -> [NSWindow] {
            NSApplication.shared.windows.filter { other in
                other !== window && other is NSPanel && other.isVisible && other.windowNumber > 0
                    && other.alphaValue > 0 && other.frame.intersects(window.frame)
            }
        }

        /// The client goes idle when `tick` returns false.
        private func finish() {
            let index = dir.appendingPathComponent("frames.json")
            let times = self.times
            let brightness = brightness
            encoder.async {
                let series = brightness.series
                let frames: [String: [Double]] = ["times": times, "luminance": series.means, "peak": series.peaks]
                if let data = try? JSONSerialization.data(withJSONObject: frames) { try? data.write(to: index) }
            }
            done()
        }
    }

    /// Each frame's brightness, in frame order. The recorder's `encoder` queue
    /// is serial, so the order is the frames' order.
    private final class Brightness: Sendable {
        nonisolated struct Series: Sendable {
            var means: [Double] = []
            var peaks: [Double] = []
        }

        private let samples = Mutex(Series())

        /// What every frame measured so far, in frame order.
        /// Nonisolated, like every member here: the module's default isolation
        /// is MainActor, and the encoder queue is the only caller.
        nonisolated var series: Series { samples.withLock { $0 } }

        nonisolated func measure(_ image: CGImage) {
            let reading = Self.brightness(of: image)
            samples.withLock {
                $0.means.append(reading.mean)
                $0.peaks.append(reading.peak)
            }
        }

        /// How bright `image` is: `mean`, its mean Rec. 709 luminance, and
        /// `peak`, the brightest of its 64 cells, so a white flash over part
        /// of the window shows even when the mean stays low. Core Graphics
        /// resamples the frame down to 8x8, which averages every pixel into a
        /// cell. Both are 0...1, and 0 when the draw fails.
        nonisolated static func brightness(of image: CGImage) -> (mean: Double, peak: Double) {
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
}
#endif
