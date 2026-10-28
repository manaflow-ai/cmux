#if canImport(UIKit)
import UIKit
import CmuxSafeConcurrency
import WebRTC

/// The streamed screen on iOS: libwebrtc's Metal renderer (hardware-decoded
/// frames go straight to the GPU). `onSize` reports the video's pixel size.
/// The delegate conformance is main-actor isolated: `RTCMTLVideoView` reports size
/// changes on the main queue (its `setSize:` dispatches to it).
public final class ScreenVideoView: UIView, @MainActor RTCVideoViewDelegate {
    public var onSize: ((CGSize) -> Void)?
    /// Called on the main queue with each rendered frame's arrival time (perf).
    public var onFrame: (() -> Void)?
    private let metal = RTCMTLVideoView(frame: .zero)
    private let tap = FrameTap()
    private var track: VideoTrackBox?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        metal.videoContentMode = .scaleToFill
        metal.delegate = self
        metal.frame = bounds
        metal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(metal)
        tap.onFrame = { [weak self] in DispatchQueue.main.async { self?.onFrame?() } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func attach(_ box: VideoTrackBox) {
        track?.track.remove(metal)
        track?.track.remove(tap)
        track = box
        box.track.add(metal)
        box.track.add(tap)
    }

    public func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        onSize?(size)
    }

    deinit {
        track?.track.remove(metal)
        track?.track.remove(tap)
    }
}

#elseif canImport(AppKit)
import AppKit
import AVFoundation
import CoreMedia
import CmuxSafeConcurrency
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
        sink = SampleBufferSink(renderer: display.sampleBufferRenderer)
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

/// libwebrtc's renderer callback (decode thread): each frame as a sample
/// buffer for the display layer, shown at once. Frames are pushed, not
/// pulled on a display link, and `DisplayImmediately` puts each one on the
/// next refresh, so a 120 fps stream presents at 120 Hz on a ProMotion
/// display with no frame rate hint (macOS has no 60 Hz cap to lift).
// Threads: libwebrtc delivers frames on its one decode thread, one at a time (its VideoBroadcaster), and only that thread
// touches `size`, `format` and `pool`; the main thread sets `onSize` in the view's init, before `attach` adds the sink to
// a track (libwebrtc's sink lock publishes it). No lock: the fields are confined to that thread, and a Mutex<State> cannot
// hold them, because each frame's pixel buffer (libwebrtc's, not Sendable) would join the guarded state. Sendable only so
// the view's nonisolated deinit may remove the sink from its track.
// crash-allow: render state confined to libwebrtc's decode thread (threads and why no lock: above).
private final class SampleBufferSink: NSObject, RTCVideoRenderer, @unchecked Sendable {
    var onSize: (@Sendable (CGSize) -> Void)?
    private let renderer: AVSampleBufferVideoRenderer
    private var size = CGSize.zero
    private var format: CMVideoFormatDescription?
    private var pool: CVPixelBufferPool?

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let pixelBuffer = pixelBuffer(of: frame) else { return }
        let pixels = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if pixels != size {
            size = pixels
            onSize?(pixels)
        }
        if !(format.map { CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) } ?? false) {
            format = try? CMVideoFormatDescription(imageBuffer: pixelBuffer)
        }
        guard let format else { return }
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        guard let sample = try? CMSampleBuffer(imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: timing) else { return }
        // The one sample's attachments dictionary (a CFMutableDictionary the array owns): bridged,
        // not cast from a raw pointer.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately as NSString] = NSNumber(value: true)
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
            // SAFETY: stores at most one +1 pool in `pool` (this object's field, touched only on
            // the decode thread); the Swift import takes ownership of it.
            _ = unsafe CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        // SAFETY: stores at most one +1 pixel buffer in the local `out`, live for this call.
        guard unsafe CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        // The pool makes width x height NV12 buffers (attributes above), so plane 0 has `height`
        // rows of >= width bytes and plane 1 has (height + 1) / 2 rows of >= 2 * ((width + 1) / 2)
        // bytes. libwebrtc's I420 buffer of the same size has `height` rows of strideY >= width Y
        // bytes and (height + 1) / 2 rows of strideU / strideV >= (width + 1) / 2 chroma bytes.
        // The planes are locked until the defer and `i420` lives to the end of this function.
        guard CVPixelBufferGetWidth(out) == width, CVPixelBufferGetHeight(out) == height else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        // SAFETY: plane 0 of the locked buffer (sizes above).
        if let y = unsafe CVPixelBufferGetBaseAddressOfPlane(out, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
            for row in 0 ..< height {
                // SAFETY: copies `width` bytes of Y row `row`, inside both planes (sizes above).
                unsafe (y + row * stride).copyMemory(from: i420.dataY + row * Int(i420.strideY), byteCount: width)
            }
        }
        // SAFETY: plane 1 of the locked buffer (sizes above); the bytes are bound as UInt8 by CoreVideo.
        if let uv = unsafe CVPixelBufferGetBaseAddressOfPlane(out, 1)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
            for row in 0 ..< (height + 1) / 2 {
                // SAFETY: the starts of chroma row `row` of the I420 U and V planes (sizes above).
                let u = unsafe i420.dataU + row * Int(i420.strideU), v = unsafe i420.dataV + row * Int(i420.strideV)
                // SAFETY: the start of interleaved chroma row `row` of plane 1 (sizes above).
                let line = unsafe uv + row * stride
                for column in 0 ..< (width + 1) / 2 {
                    // SAFETY: column < (width + 1) / 2: inside the U row, the V row and the
                    // 2 * ((width + 1) / 2) bytes of the interleaved row (sizes above).
                    unsafe line[2 * column] = u[column]
                    // SAFETY: as above.
                    unsafe line[2 * column + 1] = v[column]
                }
            }
        }
        return out
    }
}
#endif

#if canImport(UIKit) || canImport(AppKit)
/// Counts frames without rendering them: the view sets `onFrame` on the main
/// thread, libwebrtc's decode thread calls it with each frame.
private final class FrameTap: NSObject, RTCVideoRenderer, Sendable {
    private let handler = Mutex<(@Sendable () -> Void)?>(nil)

    var onFrame: (@Sendable () -> Void)? {
        get { handler.withLock { $0 } }
        set { handler.withLock { $0 = newValue } }
    }

    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) { if frame != nil { onFrame?() } }
}
#endif
