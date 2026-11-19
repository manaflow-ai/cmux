#if canImport(UIKit)
import AVFoundation
import CoreMedia
import UIKit
import WebRTC

/// The streamed screen on iOS. Decoded frames go from libwebrtc's decode thread
/// straight into the view's `AVSampleBufferDisplayLayer` (hardware-decoded frames
/// are already `CVPixelBuffer`s, so nothing is copied), as on macOS below, and each
/// is shown on the next refresh (`DisplayImmediately`).
///
/// libwebrtc's `RTCMTLVideoView`, used before, draws from an `MTKView` whose own
/// timer runs on the main thread at the view's default 60 frames a second: it
/// samples the newest frame on its tick instead of showing each one as it arrives,
/// so a 120 fps stream showed at most 60 (half the frames the Mac encoded were
/// never seen), a frame waited up to a tick before its draw, and any main-thread
/// work (SwiftUI, the toolbar, a gesture) delayed or dropped frames. Here no frame
/// touches the main thread.
///
/// `frameRate` (the rate the Mac streams at) is the display rate the view asks a
/// ProMotion screen for while it shows a stream above 60 fps. `onSize` reports the
/// video's pixel size (main queue).
public final class ScreenVideoView: UIView {
    public var onSize: ((CGSize) -> Void)?
    /// Called on the main queue with each rendered frame's arrival time (perf).
    public var onFrame: (() -> Void)?
    /// The stream's frame rate (0: unknown). Above 60, a ProMotion display is asked
    /// for it while the view is in a window (``ProMotionRate``).
    public var frameRate = 0 {
        didSet { if frameRate != oldValue { promotion.update(frameRate: frameRate, inWindow: window != nil) } }
    }
    private let sink: SampleBufferSink
    private let tap = FrameTap()
    private let promotion = ProMotionRate()
    private var track: VideoTrackBox?

    override public class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var display: AVSampleBufferDisplayLayer {
        // crash-allow: layerClass is AVSampleBufferDisplayLayer, so the view's layer always is one.
        layer as! AVSampleBufferDisplayLayer
    }

    override public init(frame: CGRect) {
        sink = SampleBufferSink()
        super.init(frame: frame)
        display.videoGravity = .resize
        display.backgroundColor = UIColor.black.cgColor
        sink.renderer = display.sampleBufferRenderer
        sink.onSize = { [weak self] size in DispatchQueue.main.async { self?.onSize?(size) } }
        tap.onFrame = { [weak self] in DispatchQueue.main.async { self?.onFrame?() } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        promotion.update(frameRate: frameRate, inWindow: window != nil)
    }

    public func attach(_ box: VideoTrackBox) {
        track?.track.remove(sink)
        track?.track.remove(tap)
        track = box
        box.track.add(sink)
        box.track.add(tap)
    }

    deinit {
        track?.track.remove(sink)
        track?.track.remove(tap)
        promotion.stop()
    }
}

/// Asks a ProMotion display for a stream's frame rate. Core Animation runs an iPhone
/// display at 60 Hz unless something on screen asks for more; a layer whose
/// contents change at 120 fps does not ask by itself. A display link with a
/// preferred frame rate range is the request (its callback does nothing). It runs
/// only while a stream above 60 fps is in a window; `CADisableMinimumFrameDurationOnPhone`
/// in the app's Info.plist lets an iPhone go above 60 at all.
@MainActor
final class ProMotionRate {
    private var link: CADisplayLink?
    private(set) var requested: Int?

    func update(frameRate: Int, inWindow: Bool) {
        let rate = ScreenQuality.requestedDisplayRate(frameRate: frameRate, inWindow: inWindow)
        guard rate != requested else { return }
        stop()
        requested = rate
        guard let rate else { return }
        let link = CADisplayLink(target: Tick.shared, selector: #selector(Tick.tick(_:)))
        let fps = Float(rate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 80), maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        requested = nil
    }

    /// The display link's target: holds no view, so the link never keeps one alive.
    private final class Tick: NSObject {
        static let shared = Tick()
        @objc func tick(_ link: CADisplayLink) {}
    }
}

#elseif canImport(AppKit)
import AppKit
import AVFoundation
import CoreMedia
import WebRTC

/// The streamed screen on macOS. Decoded frames go from libwebrtc's decode
/// thread straight into an `AVSampleBufferDisplayLayer` (hardware-decoded
/// frames are already `CVPixelBuffer`s, so nothing is copied): no rendering
/// on the main thread, which libwebrtc's `RTCMTLNSVideoView` does (its
/// texture uploads and drawable waits blocked the app's main thread). It
/// fills its bounds, so the owner sizes it to the video's aspect. `onSize`
/// reports the video's pixel size (main queue).
public final class ScreenVideoView: NSView {
    public var onSize: ((CGSize) -> Void)?
    /// Called on the main queue with each rendered frame's arrival time (perf).
    public var onFrame: (() -> Void)?
    private let display = AVSampleBufferDisplayLayer()
    private let sink: SampleBufferSink
    private let tap = FrameTap()
    private var track: VideoTrackBox?

    public override init(frame: NSRect) {
        sink = SampleBufferSink()
        sink.renderer = display.sampleBufferRenderer
        super.init(frame: frame)
        wantsLayer = true
        display.videoGravity = .resize
        display.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(display)
        sink.onSize = { [weak self] size in DispatchQueue.main.async { self?.onSize?(size) } }
        tap.onFrame = { [weak self] in DispatchQueue.main.async { self?.onFrame?() } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.frame = bounds
        CATransaction.commit()
    }

    /// Input goes to the view underneath (the owner's event view), never the renderer.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public func attach(_ box: VideoTrackBox) {
        detach()
        track = box
        box.track.add(sink)
        box.track.add(tap)
    }

    /// Stops rendering the current track (the layer keeps its last picture).
    public func detach() {
        track?.track.remove(sink)
        track?.track.remove(tap)
        track = nil
    }

    deinit {
        track?.track.remove(sink)
        track?.track.remove(tap)
    }
}

#endif

#if canImport(UIKit) || canImport(AppKit)
import AVFoundation
import CoreMedia
import WebRTC

/// libwebrtc's renderer callback (decode thread): each frame as a sample
/// buffer for the display layer, shown at once. Frames are pushed, not
/// pulled on a display link, and `DisplayImmediately` puts each one on the
/// next refresh, so a 120 fps stream presents at 120 Hz on a ProMotion Mac
/// with no frame rate hint (an iPhone also needs ``ProMotionRate``).
// crash-allow: `size`, `format` and `pool` are touched only on libwebrtc's one render thread; `renderer` and `onSize` are set before the sink is attached.
final class SampleBufferSink: NSObject, RTCVideoRenderer, @unchecked Sendable {
    // @unchecked: `size` and `format` are touched only on libwebrtc's render thread.
    var onSize: (@Sendable (CGSize) -> Void)?
    /// The display layer's renderer, set once by the owning view before the sink is attached.
    var renderer: AVSampleBufferVideoRenderer?
    private var size = CGSize.zero
    private var format: CMVideoFormatDescription?
    private var pool: CVPixelBufferPool?

    func setSize(_ size: CGSize) {}

    // perf-hot: 1ms screen-stream-present
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let renderer, let frame, let pixelBuffer = pixelBuffer(of: frame) else { return }
        let pixels = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if pixels != size {
            size = pixels
            onSize?(pixels)
        }
        if !(format.map { CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) } ?? false) {
            format = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    /// The frame's pixels: the decoder's own buffer (hardware decode), else
    /// an I420 frame copied into a pooled NV12 buffer.
    private func pixelBuffer(of frame: RTCVideoFrame) -> CVPixelBuffer? {
        if let buffer = frame.buffer as? RTCCVPixelBuffer { return buffer.pixelBuffer }
        let i420 = frame.buffer.toI420()
        let width = Int(i420.width), height = Int(i420.height)
        if pool == nil || size != CGSize(width: width, height: height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        if let y = CVPixelBufferGetBaseAddressOfPlane(out, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
            for row in 0 ..< height {
                memcpy(y + row * stride, i420.dataY + row * Int(i420.strideY), width)
            }
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(out, 1)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
            for row in 0 ..< (height + 1) / 2 {
                let u = i420.dataU + row * Int(i420.strideU), v = i420.dataV + row * Int(i420.strideV)
                let line = uv + row * stride
                for column in 0 ..< (width + 1) / 2 {
                    line[2 * column] = u[column]
                    line[2 * column + 1] = v[column]
                }
            }
        }
        return out
    }
}

/// Counts frames without rendering them.
// crash-allow: `onFrame` is set once in the view's init, before the tap is attached to a track, and only read after.
private final class FrameTap: NSObject, RTCVideoRenderer, @unchecked Sendable {
    var onFrame: (() -> Void)?
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) { if frame != nil { onFrame?() } }
}
#endif
