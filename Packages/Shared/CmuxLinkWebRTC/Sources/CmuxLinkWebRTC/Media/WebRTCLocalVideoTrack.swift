import CmuxLink
import CoreVideo
import Foundation
@preconcurrency import WebRTC

/// The publisher's side of a video track: `push` feeds `WebRTCPixelBufferBox`es
/// (or `WebRTCVideoFrameBox`es) into a libwebrtc video source, which encodes and
/// sends them with congestion control (C2 browser, C3 VNC).
final class WebRTCLocalVideoTrack: WebRTCMediaBacking, @unchecked Sendable {
    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private let track: RTCVideoTrack
    private let sender: RTCRtpSender
    private weak var connection: RTCPeerConnection?
    private let states = MediaTrackStates()

    init(peer: WebRTCPeer, descriptor: MediaTrackDescriptor) throws {
        guard let connection = peer.connection else { throw WebRTCTransportError.closed }
        let factory = peer.factory.factory
        source = factory.videoSource(forScreenCast: true)
        capturer = RTCVideoCapturer(delegate: source)
        track = factory.videoTrack(with: source, trackId: descriptor.id)
        guard let sender = connection.add(track, streamIds: ["cmux"]) else { throw WebRTCTransportError.closed }
        self.sender = sender
        self.connection = connection
    }

    func states() async -> AsyncStream<MediaTrackState> { states.stream() }

    /// Publishers have no sinks.
    func attach(_ sink: any MediaFrameSink) async {}
    func detach(_ sink: any MediaFrameSink) async {}

    func push(_ frame: MediaFrame) async {
        guard states.current == .live, case let .native(native) = frame.payload else { return }
        let videoFrame: RTCVideoFrame
        if let box = native as? WebRTCVideoFrameBox {
            videoFrame = box.frame
        } else if let box = native as? WebRTCPixelBufferBox {
            videoFrame = RTCVideoFrame(
                buffer: RTCCVPixelBuffer(pixelBuffer: box.pixelBuffer), rotation: ._0,
                timeStampNs: Int64(frame.timestamp.components.seconds) * 1_000_000_000
                    + frame.timestamp.components.attoseconds / 1_000_000_000
            )
        } else {
            return
        }
        source.capturer(capturer, didCapture: videoFrame)
    }

    func stop() async {
        end()
    }

    func end() {
        guard states.end() else { return }
        _ = connection?.removeTrack(sender)
    }
}
