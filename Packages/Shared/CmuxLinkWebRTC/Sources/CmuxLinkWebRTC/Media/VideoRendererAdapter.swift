import CmuxLink
import Foundation
@preconcurrency import WebRTC

/// Adapts a `MediaFrameSink` to libwebrtc's renderer callback.
final class VideoRendererAdapter: NSObject, RTCVideoRenderer, @unchecked Sendable {
    let sink: any MediaFrameSink

    init(sink: any MediaFrameSink) {
        self.sink = sink
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        sink.receive(MediaFrame(
            timestamp: .nanoseconds(frame.timeStampNs),
            width: Int(frame.width),
            height: Int(frame.height),
            payload: .native(WebRTCVideoFrameBox(frame: frame))
        ))
    }
}
