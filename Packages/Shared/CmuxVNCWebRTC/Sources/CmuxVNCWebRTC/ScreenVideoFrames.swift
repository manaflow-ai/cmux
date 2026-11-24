import CoreVideo
import Foundation
import WebRTC

/// Attaches a decoded track to an existing native presenter without a second view.
/// The receiver runs on libwebrtc's render thread. Keep the handle alive while rendering.
@MainActor
public final class ScreenVideoFrames {
    private let track: VideoTrackBox
    private let sink: ScreenVideoFrameSink

    /// Hardware-decoded pixels are delivered directly; software frames use pooled NV12 buffers.
    public init(track: VideoTrackBox, receive: @escaping @Sendable (CVPixelBuffer) -> Void) {
        self.track = track
        sink = ScreenVideoFrameSink(receive: receive)
        track.track.add(sink)
    }

    deinit { track.track.remove(sink) }
}

/// WebRTC serializes render calls to each attached renderer; conversion state stays there.
// crash-allow: the immutable callback and converter are used only on libwebrtc's renderer thread.
private final class ScreenVideoFrameSink: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let receive: @Sendable (CVPixelBuffer) -> Void
    private let pixels = ScreenVideoPixels()

    init(receive: @escaping @Sendable (CVPixelBuffer) -> Void) { self.receive = receive }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let buffer = pixels.pixelBuffer(of: frame) else { return }
        receive(buffer)
    }
}
