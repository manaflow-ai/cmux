@preconcurrency import WebRTC

/// A decoded libwebrtc frame handed to a `MediaFrameSink` as
/// `MediaFrame.Payload.native`. `frame.buffer` is usually an
/// `RTCCVPixelBuffer` (VideoToolbox) or an I420 buffer.
public struct WebRTCVideoFrameBox: @unchecked Sendable {
    public let frame: RTCVideoFrame
}
