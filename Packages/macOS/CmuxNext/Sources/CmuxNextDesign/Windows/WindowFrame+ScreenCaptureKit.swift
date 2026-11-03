#if DEBUG || CMUX_BENCH_HOOKS
public import CoreGraphics
import CmuxNextCompat
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

/// How ``WindowFrame/recordScreen(_:bounds:scale:from:until:)`` read the frames.
public nonisolated enum WindowFrameCapture: String, Sendable {
    /// ScreenCaptureKit with this process's own shareable content: no Screen Recording grant needed, and the
    /// Chromium pages (drawn by the GPU process) are in the frames.
    case screenCaptureKit = "screencapturekit"
    /// `CGWindowListCreateImage` back to back (``WindowFrame/recordAbove(_:bounds:scale:from:until:)``). Without the
    /// Screen Recording grant the window server leaves out what another process draws: a Chromium page comes out as
    /// its background.
    case windowList = "window_list"
}

nonisolated extension WindowFrame {
    /// The window and this app's windows over it in `bounds` (global display coordinates, top-left origin), frame
    /// after frame until `until` ms after `start`, and how they were read.
    ///
    /// Where the process lacks the Screen Recording grant (a fleet step's app answers to the build worker, which has
    /// none, and macOS keeps SIP on), `CGWindowListCreateImage` leaves the Chromium page out of every frame, so a
    /// strip over a chat measures a blank pane (cmuxterm-hq#6338). There it reads ScreenCaptureKit's current-process
    /// content (macOS 14.4+, no grant): the display showing only this app's windows, cut to `bounds`, every frame the
    /// window server composites. With the grant (or when ScreenCaptureKit fails, `error`) it reads the window list as
    /// before. `method: .windowList` asks for the window list alone. `ready` runs once, on any thread, when the first
    /// frame is in (or the window list starts): a key sent after it has a frame from before it. A first frame later than
    /// `lead` ms moves the end by as much (ScreenCaptureKit takes a moment to start), so `until - lead` ms after the
    /// key stay recorded; a stream with no frame 3 s past `until` ends.
    @concurrent public static func recordScreen(_ window: CGWindowID, bounds: CGRect, scale: Double, from start: ContinuousClock.Instant,
                                               lead: Double = 0, until: Double, method: WindowFrameCapture? = nil,
                                               ready: @escaping @Sendable () -> Void = {})
        async -> (frames: [WindowFrame], capture: WindowFrameCapture, error: String?) {
        let wanted = method ?? (CGPreflightScreenCaptureAccess() ? .windowList : .screenCaptureKit)
        var failure: String?
        if wanted == .screenCaptureKit {
            if #available(macOS 14.4, *) {
                do {
                    let stream = ScreenFrameStream(window: window, bounds: bounds, scale: scale, start: start, ready: ready)
                    let frames = try await stream.run(lead: lead, until: until)
                    if !frames.isEmpty { return (frames, .screenCaptureKit, nil) }
                    failure = "ScreenCaptureKit gave no frame"
                } catch {
                    failure = "\(error)"
                }
            } else {
                failure = "own-window ScreenCaptureKit needs macOS 14.4"
            }
        }
        // A failed stream took time: the window list still records `until - lead` ms after the key that follows `ready`.
        let end = max(until, elapsed(since: start) + until - lead)
        ready()
        return (await recordAbove(window, bounds: bounds, scale: scale, from: start, until: end), .windowList, failure)
    }
}

/// One ScreenCaptureKit stream of this app's windows in a rect, collected as ``WindowFrame``s on its own queue (no
/// main-thread work per frame). An idle frame (nothing changed on screen) repeats the last picture at its time, so
/// a still picture keeps counting frames as the window list's back-to-back reads did.
// crash-allow: `frames` and `last` are touched only on `queue` (the sample handler) and read after the stream stopped.
@available(macOS 14.4, *)
nonisolated final class ScreenFrameStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    nonisolated struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let window: CGWindowID
    private let bounds: CGRect
    private let scale: Double
    private let start: ContinuousClock.Instant
    /// Run at the first frame; nil after (touched on `queue` only).
    private var ready: (@Sendable () -> Void)?
    // concurrency-allow: held only to set or read the first frame's arrival (ms after `start`); no call out runs under it.
    private let firstAt = Mutex<Double?>(nil)
    private let queue = DispatchQueue(label: "debug.frame_strip.screen", qos: .userInitiated)
    private var frames: [WindowFrame] = []
    private var last: WindowFrame?
    // concurrency-allow: held only to set or read the stop error; no call out runs under it.
    private let stopped = Mutex<String?>(nil)

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    init(window: CGWindowID, bounds: CGRect, scale: Double, start: ContinuousClock.Instant, ready: @escaping @Sendable () -> Void) {
        self.window = window
        self.bounds = bounds
        self.scale = scale
        self.start = start
        self.ready = ready
    }

    /// Starts the stream, keeps it until `until` ms after `start` (later by as much as the first frame came after
    /// `lead`), stops it and returns the frames.
    func run(lead: Double, until: Double) async throws -> [WindowFrame] {
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == window }) else {
            throw Failure(description: "ScreenCaptureKit lists no window \(window) of this process")
        }
        guard let display = content.displays.first(where: { $0.frame.intersects(target.frame) }) ?? content.displays.first else {
            throw Failure(description: "ScreenCaptureKit lists no display for this process")
        }
        // Every on-screen window of this app on that display: the Chromium page windows and the panels over the window.
        let own = content.windows.filter { $0.isOnScreen && $0.frame.intersects(display.frame) }
        let filter = SCContentFilter(display: display, including: own.isEmpty ? [target] : own)
        let configuration = SCStreamConfiguration()
        // Points, as the window list's nominal-resolution image: frames compare the same and WindowFrame scales them.
        configuration.sourceRect = bounds.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = max(2, Int(bounds.width.rounded()))
        configuration.height = max(2, Int(bounds.height.rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240) // faster than any display: every composited frame
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 8
        configuration.scalesToFit = false
        configuration.backgroundColor = CGColor.clear
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        while true {
            let first = firstAt.withLock { $0 }
            let end = first.map { until + max(0, $0 - lead) } ?? until + 3_000
            let remaining = end - WindowFrame.elapsed(since: start)
            if remaining <= 0 { break }
            // Before the first frame, look again soon: its time sets the end.
            try? await Task.sleep(for: .milliseconds(first == nil ? min(remaining, 20) : remaining))
        }
        try? await stream.stopCapture()
        // The handler runs on `queue`: one hop after the stop has every frame it delivered.
        let collected: [WindowFrame] = await withCheckedContinuation { done in
            queue.async { [self] in done.resume(returning: frames) }
        }
        if collected.isEmpty, let reason = stopped.withLock({ $0 }) { throw Failure(description: reason) }
        return collected
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        // The frame's display time, as ms after `start`: its age now, taken from the elapsed time now.
        let shown = (info[.displayTime] as? NSNumber)?.uint64Value ?? mach_absolute_time()
        let age = Double(mach_absolute_time() &- min(shown, mach_absolute_time())) * Self.secondsPerTick * 1000
        let at = WindowFrame.elapsed(since: start) - age
        switch status {
        case .complete:
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let image = Self.image(of: buffer),
                  let frame = WindowFrame(image, scale: scale, at: at) else { return }
            frames.append(frame)
            last = frame
            if let ready {
                self.ready = nil
                firstAt.withLock { $0 = WindowFrame.elapsed(since: start) }
                ready()
            }
        case .idle:
            guard var again = last else { return }
            again.milliseconds = at
            frames.append(again)
        default:
            return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stopped.withLock { $0 = String(describing: error) }
    }

    /// A copy of a BGRA pixel buffer as an image.
    private static func image(of buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        return context.makeImage()
    }
}
#endif
