// DEBUG builds only: the screen-stream eval's on-phone latency probe. Nothing here ships in Release.
#if DEBUG && canImport(UIKit)
import AVFoundation
import CoreVideo
import Foundation
import MetalKit
import QuartzCore
import UIKit
import WebRTC

/// Times the glass-to-glass marker (`cmux-tui/crates/cmux-rd-host/scripts/mac-marker`: 20 cells,
/// counter LSB first, then guards 1,0,1,0) as the iPhone app shows it: when a decoded frame first
/// carries a counter value, and when the app's own renderer first presents that value. All on
/// `CACurrentMediaTime`, the clock Core Animation, Metal's `presentedTime` and `CADisplayLink` use.
///
/// It works with whichever renderer `ScreenVideoView` has, and needs nothing from the view:
/// `watch(_:)` finds the renderer in the view it is given, and `attach(_:)` adds the probe to the
/// video track after the view's own sinks (`ScreenSession` calls it right after `onVideoTrack`).
/// "Presented" means, per renderer (`presentClock["renderer"]`):
/// - `RTCMTLVideoView` (an `MTKView`): Metal's `presentedTime` of the first drawable whose draw
///   rendered a frame carrying the value (the presented handler's own time when the system
///   reports 0). Measured by the system. The simulator's Metal has no presented handler or
///   `presentedTime`, so there a draw that rendered a new frame counts as presented at the
///   `targetTimestamp` of the first `CADisplayLink` tick after the draw (scheduled, like below).
/// - `AVSampleBufferDisplayLayer` (`DisplayImmediately`): the `targetTimestamp` of the first
///   `CADisplayLink` tick after the frame was enqueued. The scheduled scan-out, not measured: the
///   layer reports no per-frame present. The probe's frame callback runs after the renderer's
///   (libwebrtc calls a track's sinks in order, on one thread), so its time bounds the enqueue.
///   The link runs on its own thread, so main-thread work never delays a tick.
///
/// Set `ScreenSession.debugVideoProbe` before the viewer makes its video view
/// (scripts/measure/screen-stream-eval/targets/iphone-sim.sh).
// crash-allow: the geometry is immutable, and every mutable field is read and written only under `lock`.
public final class ScreenPresentProbe: NSObject, RTCVideoRenderer, @unchecked Sendable {

    /// When a marker value first showed: decoded, and presented on the display.
    public struct Shown: Sendable {
        public var decoded: CFTimeInterval?
        public var presented: CFTimeInterval?
    }

    /// The renderer `watch(_:)` found, and what "presented" means for it.
    enum Renderer: String {
        case metal = "RTCMTLVideoView"
        case sampleBuffer = "AVSampleBufferDisplayLayer"

        var presented: String {
            switch self {
            case .metal:
                #if targetEnvironment(simulator)
                "targetTimestamp of the first CADisplayLink tick after the draw that rendered the frame (the simulator's Metal reports no presents; the scheduled scan-out, not measured)"
                #else
                "Metal presentedTime of the first drawable showing the frame (measured; the presented handler's time when the system reports 0)"
                #endif
            case .sampleBuffer:
                "targetTimestamp of the first CADisplayLink tick after the frame was enqueued with DisplayImmediately (the scheduled scan-out, not measured)"
            }
        }
    }

    /// One cell's width over the frame width, and the marker's top over the frame height.
    public let cellFraction: Double
    public let originY: Double
    private let lock = NSLock()
    private var current: UInt16?
    private var size = CGSize.zero
    private weak var track: RTCVideoTrack?
    private var renderer: Renderer?
    /// Frame timestamp (ns) to the marker value it carried, for the last 128 decoded frames.
    private var valueByTimestamp: [Int64: UInt16] = [:]
    private var timestamps: [Int64] = []
    private var decodedAt: [UInt16: CFTimeInterval] = [:]
    private var presentedAt: [UInt16: CFTimeInterval] = [:]
    private var waiter: (value: UInt16, resume: CheckedContinuation<Shown?, Never>)?
    /// Metal: presents timed by `presentedTime`, and by the handler's time (the system reported 0).
    private var presentedTimes = 0
    private var handlerTimes = 0
    private var presents = 0
    /// Sample buffer layer: frames handed to the layer and not yet credited to a tick, in order.
    private var handed: [(value: UInt16, at: CFTimeInterval)] = []
    private var displayLinkStarted = false
    private var ticks = 0
    private var tickInterval: (min: CFTimeInterval, max: CFTimeInterval)?
    /// Every Metal hook installed (an `MTKView` holds its delegate weakly); dead views' are dropped.
    private var metalHooks: [PresentHook] = []
    /// Why presents are not observed (no renderer the probe knows), or nil.
    private var hookProblem: String?

    public init(cellFraction: Double, originY: Double) {
        self.cellFraction = cellFraction
        self.originY = originY
    }

    public var value: UInt16? { lock.withLock { current } }
    public var frameSize: CGSize { lock.withLock { size } }
    /// The renderer presents are timed on (nil until `watch(_:)` finds one).
    public var rendererName: String? { lock.withLock { renderer?.rawValue } }

    /// How presents were timed: the renderer, what "presented" means for it, its counts, and the
    /// hook's problem when presents could not be observed.
    public var presentClock: [String: Any] {
        lock.withLock { () -> [String: Any] in
            var clock: [String: Any] = [
                "renderer": renderer.map { $0.rawValue as Any } ?? NSNull(),
                "presented": renderer.map { $0.presented as Any } ?? NSNull(),
                "hook_problem": hookProblem.map { $0 as Any } ?? NSNull(),
            ]
            switch renderer {
            case .metal:
                clock["presents"] = presents
                clock["presented_time"] = presentedTimes
                clock["handler_time"] = handlerTimes
                #if targetEnvironment(simulator)
                clock["display_link_ticks"] = ticks
                clock["tick_ms_min"] = tickInterval.map { $0.min * 1000 as Any } ?? NSNull()
                clock["tick_ms_max"] = tickInterval.map { $0.max * 1000 as Any } ?? NSNull()
                #endif
            case .sampleBuffer:
                clock["display_link_ticks"] = ticks
                clock["tick_ms_min"] = tickInterval.map { $0.min * 1000 as Any } ?? NSNull()
                clock["tick_ms_max"] = tickInterval.map { $0.max * 1000 as Any } ?? NSNull()
            case nil:
                break
            }
            return clock
        }
    }

    // MARK: Wiring

    /// Finds the renderer inside `view` (a `ScreenVideoView`) and hooks its presents. Call right
    /// after the view is made.
    @MainActor
    public func watch(_ view: UIView) {
        if let metal = Self.first(RTCMTLVideoView.self, in: view) {
            let hook = PresentHook(video: metal, probe: self)
            let start = lock.withLock { () -> Bool in
                renderer = .metal
                metalHooks.removeAll { !$0.isLive }
                if hook.isLive { metalHooks.append(hook) }
                #if targetEnvironment(simulator)
                defer { displayLinkStarted = true }
                return !displayLinkStarted
                #else
                return false
                #endif
            }
            if start { DisplayTick.start(for: self) }
        } else if Self.hasSampleBufferLayer(view.layer) {
            let start = lock.withLock { () -> Bool in
                renderer = .sampleBuffer
                defer { displayLinkStarted = true }
                return !displayLinkStarted
            }
            if start { DisplayTick.start(for: self) }
        } else {
            hookFailed("\(type(of: view)) has neither an RTCMTLVideoView nor an AVSampleBufferDisplayLayer")
        }
    }

    /// Adds the probe to `box`'s track (and leaves the one before). Call after the view attached
    /// its own sinks, so the probe's frame callback follows the renderer's.
    public func attach(_ box: VideoTrackBox) {
        let old = lock.withLock { () -> RTCVideoTrack? in
            defer { track = box.track }
            return track
        }
        old?.remove(self)
        box.track.add(self)
    }

    // MARK: RTCVideoRenderer (libwebrtc's decode thread, after the view's sinks)

    public func setSize(_ size: CGSize) {}

    public func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let now = CACurrentMediaTime()
        guard let value = Self.marker(in: frame, cellFraction: cellFraction, originY: originY) else { return }
        lock.withLock {
            size = CGSize(width: Int(frame.width), height: Int(frame.height))
            current = value
            if valueByTimestamp[frame.timeStampNs] == nil {
                timestamps.append(frame.timeStampNs)
                if timestamps.count > 128 { valueByTimestamp[timestamps.removeFirst()] = nil }
            }
            valueByTimestamp[frame.timeStampNs] = value
            if decodedAt[value] == nil { decodedAt[value] = now }
            if renderer == .sampleBuffer {
                // The layer's sink enqueued this frame before this callback began.
                handed.append((value, now))
                if handed.count > 128 { handed.removeFirst() }
            }
        }
    }

    // MARK: A sample buffer layer outside WebRTC

    /// A picture the app's own decoder handed to an `AVSampleBufferDisplayLayer` with
    /// `DisplayImmediately` (the `cmux.rd/1` viewer's `BrowserVideoDecoder`), called right after
    /// the enqueue: decoded and presented are timed as for the WebRTC sample buffer renderer.
    public func enqueued(_ pixels: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        let start = lock.withLock { () -> Bool in
            renderer = .sampleBuffer
            defer { displayLinkStarted = true }
            return !displayLinkStarted
        }
        if start { DisplayTick.start(for: self) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        guard let value = Self.marker(in: pixels, cellFraction: cellFraction, originY: originY) else { return }
        lock.withLock {
            size = CGSize(width: width, height: height)
            current = value
            if decodedAt[value] == nil { decodedAt[value] = now }
            handed.append((value, now))
            if handed.count > 128 { handed.removeFirst() }
        }
    }

    // MARK: Presents

    /// Metal: the renderer presented a drawable holding the frame stamped `timeStampNs`.
    /// `presentedTime` is Metal's (0 when the system reports none), `callbackAt` when the handler ran.
    fileprivate func presented(timeStampNs: Int64, presentedTime: CFTimeInterval, callbackAt: CFTimeInterval) {
        let resume = lock.withLock { () -> (CheckedContinuation<Shown?, Never>, Shown)? in
            presents += 1
            let at: CFTimeInterval
            if presentedTime > 0 {
                presentedTimes += 1
                at = presentedTime
            } else {
                handlerTimes += 1
                at = callbackAt
            }
            guard let value = valueByTimestamp[timeStampNs] else { return nil }
            return credit(value, presentedAt: at)
        }
        if let resume { resume.0.resume(returning: resume.1) }
    }

    /// Metal in the simulator: a draw rendered the frame stamped `timeStampNs` at `drawnAt`; the
    /// next display link tick credits it, as it does a frame handed to a sample buffer layer.
    fileprivate func drew(timeStampNs: Int64, drawnAt: CFTimeInterval) {
        lock.withLock {
            presents += 1
            guard let value = valueByTimestamp[timeStampNs] else { return }
            handed.append((value, drawnAt))
            if handed.count > 128 { handed.removeFirst() }
        }
    }

    /// A display link tick (its own thread). Every frame handed to the layer, or drawn by Metal in
    /// the simulator, before this callback began is presented at the tick's `targetTimestamp`.
    fileprivate func ticked(timestamp: CFTimeInterval, target: CFTimeInterval, callbackAt: CFTimeInterval) {
        let resumes = lock.withLock { () -> [(CheckedContinuation<Shown?, Never>, Shown)] in
            ticks += 1
            let interval = target - timestamp
            if interval > 0 {
                tickInterval = (min(tickInterval?.min ?? interval, interval), max(tickInterval?.max ?? interval, interval))
            }
            let due = handed.prefix { $0.at <= callbackAt }
            handed.removeFirst(due.count)
            return due.compactMap { credit($0.value, presentedAt: target) }
        }
        for resume in resumes { resume.0.resume(returning: resume.1) }
    }

    /// Records `value`'s first present; ends the wait it answers. Under `lock`.
    private func credit(_ value: UInt16, presentedAt at: CFTimeInterval) -> (CheckedContinuation<Shown?, Never>, Shown)? {
        if presentedAt[value] == nil { presentedAt[value] = at }
        // A frame at or past the awaited value ends the wait: the renderer may skip a frame the
        // decoder replaced before the next display refresh.
        guard let waiter, Self.reached(value, waiter.value) else { return nil }
        self.waiter = nil
        return (waiter.resume, Shown(decoded: firstDecoded(atOrPast: waiter.value), presented: at))
    }

    fileprivate func hookFailed(_ problem: String) {
        lock.withLock { hookProblem = problem }
    }

    // MARK: Waiting

    /// When `value` first showed: the first present at or past it, with the first decoded frame
    /// at or past it. Nil when `cancelWait` ends the wait first.
    public func firstShown(_ value: UInt16) async -> Shown? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Shown?, Never>) in
            let done = lock.withLock { () -> Shown? in
                // The earliest present of any value at or past it (a Dictionary has no order).
                if let presented = presentedAt.filter({ Self.reached($0.key, value) }).map(\.value).min() {
                    return Shown(decoded: firstDecoded(atOrPast: value), presented: presented)
                }
                waiter = (value, continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    /// Ends a wait that did not finish in time; returns the decoded time of the awaited value, if
    /// it was decoded but never presented.
    public func cancelWait() -> CFTimeInterval? {
        let (resume, decoded) = lock.withLock { () -> (CheckedContinuation<Shown?, Never>?, CFTimeInterval?) in
            defer { waiter = nil }
            return (waiter?.resume, waiter.flatMap { firstDecoded(atOrPast: $0.value) })
        }
        resume?.resume(returning: nil)
        return decoded
    }

    /// Forgets every value's times before the next input, so a stale value never ends a wait.
    public func reset() {
        lock.withLock {
            decodedAt.removeAll()
            presentedAt.removeAll()
        }
    }

    private func firstDecoded(atOrPast value: UInt16) -> CFTimeInterval? {
        decodedAt.filter { Self.reached($0.key, value) }.map(\.value).min()
    }

    /// `value` is `target` or within half the counter's range after it (the counter wraps).
    private static func reached(_ value: UInt16, _ target: UInt16) -> Bool {
        value &- target < 0x8000
    }

    // MARK: Finding the renderer

    @MainActor
    private static func first<View: UIView>(_ type: View.Type, in view: UIView) -> View? {
        if let view = view as? View { return view }
        for subview in view.subviews {
            if let found = first(type, in: subview) { return found }
        }
        return nil
    }

    @MainActor
    private static func hasSampleBufferLayer(_ layer: CALayer) -> Bool {
        layer is AVSampleBufferDisplayLayer || (layer.sublayers ?? []).contains { hasSampleBufferLayer($0) }
    }

    // MARK: The marker

    private static func marker(in frame: RTCVideoFrame, cellFraction: Double, originY: Double) -> UInt16? {
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            // The frame's own size (a cropped buffer's picture is smaller than its planes).
            return marker(in: buffer.pixelBuffer, cellFraction: cellFraction, originY: originY,
                          size: (Int(frame.width), Int(frame.height)))
        }
        let i420 = frame.buffer.toI420()
        return marker(width: Int(frame.width), height: Int(frame.height), cellFraction: cellFraction, originY: originY) { x, y in
            i420.dataY[y * Int(i420.strideY) + x]
        }
    }

    /// The marker in a bi-planar (NV12) or other planar picture's first plane, the luma; `size`
    /// is the picture's when it is not the plane's.
    static func marker(in pixels: CVPixelBuffer, cellFraction: Double, originY: Double,
                       size: (width: Int, height: Int)? = nil) -> UInt16? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferIsPlanar(pixels), let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let size = size ?? (CVPixelBufferGetWidthOfPlane(pixels, 0), CVPixelBufferGetHeightOfPlane(pixels, 0))
        return marker(width: size.width, height: size.height, cellFraction: cellFraction, originY: originY) { x, y in bytes[y * stride + x] }
    }

    /// The counter in a `width` x `height` luma plane (video range), nil when the guards don't read.
    static func marker(width: Int, height: Int, cellFraction: Double, originY: Double,
                       luma: (Int, Int) -> UInt8) -> UInt16? {
        let cell = cellFraction * Double(width)
        let top = originY * Double(height)
        let y = Int(top + cell / 2)
        guard cell > 0, y >= 0, y < height, Int(19.5 * cell) < width else { return nil }
        var bits = [Bool](repeating: false, count: 20)
        for i in 0 ..< 20 {
            bits[i] = luma(Int((Double(i) + 0.5) * cell), y) > 125
        }
        guard Array(bits[16...]) == [true, false, true, false] else { return nil }
        return bits[..<16].enumerated().reduce(0) { $0 | (($1.element ? 1 : 0) << UInt16($1.offset)) }
    }
}

// MARK: - Metal (RTCMTLVideoView)

/// Stands in as the delegate of `RTCMTLVideoView`'s own `MTKView` and forwards every call to it
/// unchanged. Before a draw that renders a new frame, it adds a presented handler to the drawable
/// the renderer is about to present (`MTKView.currentDrawable` is this draw's one drawable), so the
/// probe learns when that frame reached the display, not when it was decoded. A draw renders a new
/// frame when `RTCMTLVideoView`'s `videoFrame` is not `lastFrameTimeNs` (the renderer's own skip
/// test); the frame drawn is `lastFrameTimeNs` after it. Both are read only when the view answers
/// them. The probe keeps the hook (an `MTKView`'s delegate is weak); the hook keeps no probe.
@MainActor
private final class PresentHook: NSObject {
    private weak var original: (any MTKViewDelegate)?
    private weak var video: RTCMTLVideoView?
    private weak var mtkView: MTKView?
    private weak var probe: ScreenPresentProbe?

    init(video: RTCMTLVideoView, probe: ScreenPresentProbe) {
        self.probe = probe
        self.video = video
        super.init()
        guard let view = video.subviews.compactMap({ $0 as? MTKView }).first, let delegate = view.delegate else {
            probe.hookFailed("RTCMTLVideoView has no MTKView with a delegate")
            return
        }
        // Watched twice: the hook already there (kept by the probe) stays.
        guard !(delegate is PresentHook) else { return }
        // crash-allow: responds(to:) only asks; it never raises for an unknown selector.
        guard video.responds(to: NSSelectorFromString("videoFrame")),
              video.responds(to: NSSelectorFromString("lastFrameTimeNs")) else {  // crash-allow: responds(to:) never raises
            probe.hookFailed("RTCMTLVideoView answers no videoFrame/lastFrameTimeNs")
            return
        }
        original = delegate
        mtkView = view
        view.delegate = self
    }

    /// Installed and its view still alive.
    var isLive: Bool { mtkView != nil && original != nil }

    /// Whether this draw renders a new frame (the renderer's own skip test).
    /// Race: the decode thread can swap `videoFrame` between this read and the renderer's own, so
    /// the frame is credited from `lastFrameTimeNs` after the draw, the one the renderer drew.
    func drawsNewFrame() -> Bool {
        // crash-allow: init installs the hook only when the view answers videoFrame.
        guard let video, let frame = video.value(forKey: "videoFrame") as? RTCVideoFrame,
              frame.width > 0, frame.height > 0 else { return false }
        return frame.timeStampNs != lastDrawn()
    }

    func lastDrawn() -> Int64? {
        // crash-allow: init installs the hook only when the view answers lastFrameTimeNs.
        (video?.value(forKey: "lastFrameTimeNs") as? NSNumber)?.int64Value
    }
}

/// The timestamp of the frame a draw rendered: written on the main thread after the draw, read by
/// Metal's presented handler, which runs after the drawable reaches the display.
// crash-allow: `timeStampNs` is read and written only under `lock`.
private final class DrawnFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64?
    var timeStampNs: Int64? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

extension PresentHook: @preconcurrency MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        original?.mtkView(view, drawableSizeWillChange: size)
    }

    func draw(in view: MTKView) {
        guard let probe, drawsNewFrame(), !view.bounds.isEmpty, let drawable = view.currentDrawable else {
            original?.draw(in: view)
            return
        }
        let before = lastDrawn()
        #if targetEnvironment(simulator)
        _ = drawable
        original?.draw(in: view)
        if let after = lastDrawn(), after != before { probe.drew(timeStampNs: after, drawnAt: CACurrentMediaTime()) }
        #else
        // The handler goes on before the renderer presents; the frame it drew is known after.
        let drawn = DrawnFrame()
        drawable.addPresentedHandler(Self.presentedHandler(probe: probe, drawn: drawn))
        original?.draw(in: view)
        if let after = lastDrawn(), after != before { drawn.timeStampNs = after }
        #endif
    }

    #if !targetEnvironment(simulator)
    /// Made outside the main actor: Metal calls it on its own thread.
    nonisolated private static func presentedHandler(probe: ScreenPresentProbe, drawn: DrawnFrame)
        -> @Sendable (any MTLDrawable) -> Void {
        { presented in
            guard let timeStampNs = drawn.timeStampNs else { return }
            probe.presented(timeStampNs: timeStampNs, presentedTime: presented.presentedTime,
                            callbackAt: CACurrentMediaTime())
        }
    }
    #endif
}

// MARK: - Sample buffer layer (AVSampleBufferDisplayLayer)

/// The probe's display link, on a thread of its own so main-thread work never delays or drops a
/// tick. It asks for no frame rate (`preferredFrameRateRange` stays default), so it does not
/// change the display's rate; `presentClock` reports the tick intervals it saw. It stops when the
/// probe is gone (the link's run loop then has nothing left and the thread ends).
private final class DisplayTick: NSObject {
    private weak var probe: ScreenPresentProbe?

    private init(probe: ScreenPresentProbe?) {
        self.probe = probe
    }

    static func start(for probe: ScreenPresentProbe) {
        let thread = Thread { [weak probe] in
            let tick = DisplayTick(probe: probe)
            let link = CADisplayLink(target: tick, selector: #selector(DisplayTick.tick(_:)))
            link.add(to: .current, forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "ScreenPresentProbe.displayLink"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    @objc func tick(_ link: CADisplayLink) {
        let callbackAt = CACurrentMediaTime()
        guard let probe else {
            link.invalidate()
            return
        }
        probe.ticked(timestamp: link.timestamp, target: link.targetTimestamp, callbackAt: callbackAt)
    }
}
#endif
