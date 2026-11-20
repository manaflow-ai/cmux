#if DEBUG || CMUX_BENCH_HOOKS
public import CoreGraphics
import CmuxNextCompat
import CmuxNextWakeups
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

/// How a frame strip read its frames (``FrameStripRecording``).
public nonisolated enum WindowFrameCapture: String, Sendable {
    /// ScreenCaptureKit with this process's own shareable content: no Screen Recording grant needed, and the
    /// Chromium pages (drawn by the GPU process) are in the frames.
    case screenCaptureKit = "screencapturekit"
    /// `CGWindowListCreateImage` back to back (``WindowFrame/recordAbove(_:bounds:scale:from:until:)``,
    /// ``WindowFrame/record(_:scale:crop:from:until:)``). Without the Screen Recording grant the window server leaves
    /// out what another process draws: a Chromium page comes out as its background.
    case windowList = "window_list"
}

/// One frame strip's recording (`debug.new_tab {action: "frame_strip"}`), started at `start`: the window's composited
/// image (`crop`), or with `above` the screen in that rect, this app's windows over the window (its Chromium pages)
/// included.
///
/// `above` without the Screen Recording grant (a fleet step's app answers to the build worker, which has none, and
/// macOS keeps SIP on) reads ScreenCaptureKit's current-process content (macOS 14.4+, no grant): the display showing
/// only this app's windows, cut to `above`, every frame the window server composites. The window list there leaves
/// the Chromium page out of every frame, so a strip over a chat measured a blank pane (cmuxterm-hq#6338). With the
/// grant, with `capture: "window_list"`, or when ScreenCaptureKit fails (`capture_error`), the window list as before.
///
/// ScreenCaptureKit takes a moment to give its first frame: ``waitForLead()`` waits for it as well as the `lead`, and
/// the recording ends as much later, so `duration` ms after the key stay recorded.
public nonisolated final class FrameStripRecording: Sendable {
    public typealias Recorded = (frames: [WindowFrame], capture: WindowFrameCapture, error: String?)
    private let lead: Double
    private let firstFrame = FrameSignal()
    private let task: Task<Recorded, Never>

    public init(_ window: CGWindowID, above: CGRect?, crop: CGRect?, scale: Double, from start: ContinuousClock.Instant,
                lead: Double, duration: Double, capture: String?) {
        self.lead = lead
        let first = firstFrame
        let until = lead + duration
        let asked = capture.flatMap(WindowFrameCapture.init(rawValue:))
        task = Task.detached(priority: .userInitiated) {
            defer { first.fire() }
            guard let above else {
                first.fire()
                return (await WindowFrame.record(window, scale: scale, crop: crop, from: start, until: until), .windowList, nil)
            }
            var failure: String?
            if (asked ?? (CGPreflightScreenCaptureAccess() ? .windowList : .screenCaptureKit)) == .screenCaptureKit {
                if #available(macOS 14.4, *) {
                    do {
                        let stream = ScreenFrameStream(window: window, bounds: above, scale: scale, start: start, first: first)
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
            // A failed stream took time: the window list still records `duration` ms after the key that follows.
            let end = max(until, WindowFrame.elapsed(since: start) + duration)
            first.fire()
            return (await WindowFrame.recordAbove(window, bounds: above, scale: scale, from: start, until: end), .windowList, failure)
        }
    }

    /// Returns `lead` ms after the start, or once the first frame is in when that is later: a key sent then has a
    /// frame from before it.
    public func waitForLead() async {
        await FrameSignal.pause(milliseconds: lead, owner: "debug.frame_strip.lead")
        await firstFrame.untilFired()
    }

    /// The frames, and the report's fields about them: `capture`, `capture_error`, and `lead_ms` (`sentAt`, when the
    /// key went in, ms after the start).
    public func result(sentAt: Double) async -> (frames: [WindowFrame], fields: [String: any Sendable]) {
        let result = await task.value
        var fields: [String: any Sendable] = ["capture": result.capture.rawValue, "lead_ms": sentAt.rounded()]
        if let error = result.error { fields["capture_error"] = error }
        return (result.frames, fields)
    }
}

/// Fires once; ``untilFired()`` returns at once after that. Any thread.
nonisolated final class FrameSignal: Sendable {
    // concurrency-allow: held only to read or set the flag and take the waiters; resuming them happens after the unlock.
    private let state = Mutex<(fired: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.fired else { return [] }
            state.fired = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func untilFired() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.fired { return true }
                state.waiters.append(done)
                return false
            }
            if now { done.resume() }
        }
    }

    /// Returns when this fires or after `milliseconds`, whichever comes first.
    func untilFired(orAfter milliseconds: Double, owner: String) async {
        let timer = DemandTimer(owner: owner)
        defer { timer.cancel() }
        timer.schedule(after: .milliseconds(Int(max(0, milliseconds).rounded(.up)))) { [self] in fire() }
        await untilFired()
    }

    /// Returns after `milliseconds` (a demand timer; at once for none).
    static func pause(milliseconds: Double, owner: String) async {
        guard milliseconds > 0 else { return }
        await FrameSignal().untilFired(orAfter: milliseconds, owner: owner)
    }
}

/// One ScreenCaptureKit stream of this app's windows in a rect, collected as ``WindowFrame``s on its own queue (no
/// main-thread work per frame). An idle frame (nothing changed on screen) repeats the last picture at its time, so
/// a still picture keeps counting frames as the window list's back-to-back reads did.
@available(macOS 14.4, *)
nonisolated final class ScreenFrameStream: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    nonisolated struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let window: CGWindowID
    private let bounds: CGRect
    private let scale: Double
    private let start: ContinuousClock.Instant
    /// Fired at the first frame (the strip's key waits for it).
    private let first: FrameSignal
    /// Fired at the first frame or a stop: the end waits for it, at most 3 s past `until`.
    private let started = FrameSignal()
    private let queue = DispatchQueue(label: "debug.frame_strip.screen", qos: .userInitiated)
    nonisolated struct Collected: Sendable {
        var frames: [WindowFrame] = []
        var last: WindowFrame?
        /// When the first frame came, ms after `start`.
        var firstAt: Double?
    }

    // concurrency-allow: written by the sample handler on `queue`, read after a hop onto it; held only to append or copy.
    private let collected = Mutex(Collected())
    // concurrency-allow: held only to set or read the stop error; no call out runs under it.
    private let stopped = Mutex<String?>(nil)

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    init(window: CGWindowID, bounds: CGRect, scale: Double, start: ContinuousClock.Instant, first: FrameSignal) {
        self.window = window
        self.bounds = bounds
        self.scale = scale
        self.start = start
        self.first = first
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
        await started.untilFired(orAfter: until + 3_000 - WindowFrame.elapsed(since: start), owner: "debug.frame_strip.first")
        let firstMs = collected.withLock { $0.firstAt }
        let end = firstMs.map { until + max(0, $0 - lead) } ?? until + 3_000
        await FrameSignal.pause(milliseconds: end - WindowFrame.elapsed(since: start), owner: "debug.frame_strip.end")
        try? await stream.stopCapture()
        // The handler runs on `queue`: one hop after the stop has every frame it delivered.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        let frames = collected.withLock { $0.frames }
        if frames.isEmpty, let reason = stopped.withLock({ $0 }) { throw Failure(description: reason) }
        return frames
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        // The frame's display time, as ms after `start`: its age now, taken from the elapsed time now.
        let now = mach_absolute_time()
        let shown = min((info[.displayTime] as? NSNumber)?.uint64Value ?? now, now)
        let at = WindowFrame.elapsed(since: start) - Double(now - shown) * Self.secondsPerTick * 1000
        switch status {
        case .complete:
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let image = Self.image(of: buffer),
                  let frame = WindowFrame(image, scale: scale, at: at) else { return }
            let arrived = WindowFrame.elapsed(since: start)
            let isFirst = collected.withLock { state -> Bool in
                state.frames.append(frame)
                state.last = frame
                guard state.firstAt == nil else { return false }
                state.firstAt = arrived
                return true
            }
            if isFirst {
                first.fire()
                started.fire()
            }
        case .idle:
            collected.withLock { state in
                guard var again = state.last else { return }
                again.milliseconds = at
                state.frames.append(again)
            }
        default:
            return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stopped.withLock { $0 = String(describing: error) }
        started.fire()
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
