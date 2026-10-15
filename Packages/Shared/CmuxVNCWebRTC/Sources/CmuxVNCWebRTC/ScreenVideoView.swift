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

/// Counts frames without rendering them.
private final class FrameTap: NSObject, RTCVideoRenderer, @unchecked Sendable {
    var onFrame: (() -> Void)?
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) { if frame != nil { onFrame?() } }
}
#endif
