#if canImport(UIKit)
import UIKit
import WebRTC

/// The streamed screen on iOS: libwebrtc's Metal renderer (hardware-decoded
/// frames go straight to the GPU). `onSize` reports the video's pixel size.
public final class ScreenVideoView: UIView, @preconcurrency RTCVideoViewDelegate {
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
// crash-allow: `size`, `format` and `pool` are touched only on libwebrtc's one render thread; `onSize` is set before the sink is attached.
private final class SampleBufferSink: NSObject, RTCVideoRenderer, @unchecked Sendable {
    // @unchecked: `size` and `format` are touched only on libwebrtc's render thread.
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
#endif

#if canImport(UIKit) || canImport(AppKit)
/// Counts frames without rendering them.
// crash-allow: `onFrame` is set once in the view's init, before the tap is attached to a track, and only read after.
private final class FrameTap: NSObject, RTCVideoRenderer, @unchecked Sendable {
    var onFrame: (() -> Void)?
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) { if frame != nil { onFrame?() } }
}
#endif
