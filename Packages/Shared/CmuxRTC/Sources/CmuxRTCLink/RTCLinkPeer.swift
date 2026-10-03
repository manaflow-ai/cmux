import CmuxRTCSignal
import CoreVideo
import Foundation
@preconcurrency import WebRTC

/// The signaling a peer produces and consumes (one session's offer, answer and candidates).
public enum RTCLinkSignal: Sendable, Equatable {
    case description(type: String, sdp: String)
    case candidate(sdp: String, mid: String?, mlineIndex: Int32)
}

public enum RTCLinkState: Sendable, Equatable {
    case new
    case connecting
    case connected
    /// ICE lost the path; libwebrtc may still recover, and the owner may restart ICE.
    case disconnected
    case failed
    case closed
}

/// A received video track (a Mac view streamed to the phone).
public struct RTCLinkVideoTrack: @unchecked Sendable {
    /// The media stream id the sender chose (`view:<id>`).
    public let streamID: String
    public let track: RTCVideoTrack
}

/// libwebrtc wants one factory per process.
public enum RTCLinkRuntime {
    public nonisolated(unsafe) static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
}

/// One WebRTC peer connection between a phone and a Mac. Perfect negotiation: the phone is polite
/// (it yields on an offer collision), the Mac is impolite. Candidates trickle through `onSignal`
/// and are buffered on receipt until the remote description is set. Data channels are in-band
/// (ordered, reliable); the answering side receives them on `incomingChannels`.
public final class RTCLinkPeer: NSObject, @unchecked Sendable {
    public let polite: Bool
    public nonisolated let states: AsyncStream<RTCLinkState>
    public nonisolated let incomingChannels: AsyncStream<RTCByteChannel>
    public nonisolated let incomingVideo: AsyncStream<RTCLinkVideoTrack>
    private let stateContinuation: AsyncStream<RTCLinkState>.Continuation
    private let channelContinuation: AsyncStream<RTCByteChannel>.Continuation
    private let videoContinuation: AsyncStream<RTCLinkVideoTrack>.Continuation
    private let onSignal: @Sendable (RTCLinkSignal) -> Void
    private let queue = DispatchQueue(label: "cmux.rtc.link")
    private var connection: RTCPeerConnection!
    private var makingOffer = false
    private var ignoreOffer = false
    private var pendingCandidates: [RTCIceCandidate] = []
    private var closed = false
    private var senders: [String: RTCRtpSender] = [:]

    public init(polite: Bool, ice: RTCIceConfiguration, onSignal: @escaping @Sendable (RTCLinkSignal) -> Void) {
        self.polite = polite
        self.onSignal = onSignal
        (states, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        (incomingChannels, channelContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (incomingVideo, videoContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        super.init()
        let config = Self.configuration(ice)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        connection = RTCLinkRuntime.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        stateContinuation.yield(.new)
    }

    static func configuration(_ ice: RTCIceConfiguration) -> RTCConfiguration {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        config.enableImplicitRollback = true
        config.iceServers = ice.servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        return config
    }

    /// Opens an ordered, reliable channel. On the offering side the first channel triggers the offer.
    public func openChannel(label: String) -> RTCByteChannel? {
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        guard let channel = connection.dataChannel(forLabel: label, configuration: config) else { return nil }
        return RTCByteChannel(channel: channel)
    }

    /// Applies one remote signal (perfect negotiation receive path).
    public func receive(_ signal: RTCLinkSignal) {
        queue.async { [self] in
            guard !closed else { return }
            switch signal {
            case let .description(type, sdp):
                let isOffer = type == "offer"
                let collision = isOffer && (makingOffer || connection.signalingState != .stable)
                ignoreOffer = !polite && collision
                if ignoreOffer { return }
                let description = RTCSessionDescription(type: RTCSessionDescription.type(for: type), sdp: sdp)
                connection.setRemoteDescription(description) { [self] error in
                    queue.async { [self] in
                        guard error == nil else { return }
                        let buffered = pendingCandidates
                        pendingCandidates.removeAll()
                        for candidate in buffered { connection.add(candidate) { _ in } }
                        guard isOffer else { return }
                        answer()
                    }
                }
            case let .candidate(sdp, mid, index):
                let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
                if connection.remoteDescription == nil {
                    pendingCandidates.append(candidate)
                } else {
                    connection.add(candidate) { _ in }
                }
            }
        }
    }

    private func answer() {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        connection.answer(for: constraints) { [self] answer, _ in
            guard let answer else { return }
            connection.setLocalDescription(answer) { [self] error in
                guard error == nil, let local = connection.localDescription else { return }
                onSignal(.description(type: RTCSessionDescription.string(for: local.type), sdp: local.sdp))
            }
        }
    }

    private func negotiate() {
        queue.async { [self] in
            guard !closed else { return }
            makingOffer = true
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            connection.offer(for: constraints) { [self] offer, _ in
                guard let offer else {
                    queue.async { self.makingOffer = false }
                    return
                }
                connection.setLocalDescription(offer) { [self] error in
                    queue.async { [self] in
                        makingOffer = false
                        guard error == nil, let local = connection.localDescription else { return }
                        onSignal(.description(type: RTCSessionDescription.string(for: local.type), sdp: local.sdp))
                    }
                }
            }
        }
    }

    /// After a network change (Wi-Fi to cellular) or an ICE failure: new candidates, same channels.
    public func restartIce() {
        queue.async { [self] in
            guard !closed else { return }
            connection.restartIce()
        }
    }

    /// Refreshes TURN credentials before they expire without dropping the session.
    public func update(ice: RTCIceConfiguration) {
        queue.async { [self] in
            guard !closed else { return }
            _ = connection.setConfiguration(Self.configuration(ice))
        }
    }

    public func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            connection.close()
            stateContinuation.yield(.closed)
            stateContinuation.finish()
            channelContinuation.finish()
            videoContinuation.finish()
        }
    }

    // MARK: Video (Mac sends, phone receives)

    /// Adds an outgoing video track in media stream `streamID`; renegotiates.
    public func addVideoSender(streamID: String) -> RTCLinkVideoSender {
        let source = RTCLinkRuntime.factory.videoSource()
        let track = RTCLinkRuntime.factory.videoTrack(with: source, trackId: streamID)
        let sender = connection.add(track, streamIds: [streamID])
        queue.async { [self] in senders[streamID] = sender }
        return RTCLinkVideoSender(source: source, track: track)
    }

    public func removeVideoSender(streamID: String) {
        queue.async { [self] in
            guard let sender = senders.removeValue(forKey: streamID) else { return }
            _ = connection.removeTrack(sender)
        }
    }
}

/// Pushes frames into one outgoing video track.
public final class RTCLinkVideoSender: @unchecked Sendable {
    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    public let track: RTCVideoTrack

    init(source: RTCVideoSource, track: RTCVideoTrack) {
        self.source = source
        self.track = track
        capturer = RTCVideoCapturer(delegate: source)
    }

    /// Hands one captured frame to the encoder. `timestampNs` is monotonic nanoseconds.
    public func push(_ pixelBuffer: CVPixelBuffer, timestampNs: Int64) {
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timestampNs)
        source.capturer(capturer, didCapture: frame)
    }

    /// Caps resolution and frame rate (data saver vs high quality).
    public func adapt(width: Int32, height: Int32, fps: Int32) {
        source.adaptOutputFormat(toWidth: width, height: height, fps: fps)
    }
}

extension RTCLinkPeer: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) { negotiate() }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onSignal(.candidate(sdp: candidate.sdp, mid: candidate.sdpMid, mlineIndex: candidate.sdpMLineIndex))
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        channelContinuation.yield(RTCByteChannel(channel: dataChannel))
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let mapped: RTCLinkState
        switch newState {
        case .new: mapped = .new
        case .connecting: mapped = .connecting
        case .connected: mapped = .connected
        case .disconnected: mapped = .disconnected
        case .failed: mapped = .failed
        case .closed: mapped = .closed
        @unknown default: return
        }
        stateContinuation.yield(mapped)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        let streamID = mediaStreams.first?.streamId ?? track.trackId
        videoContinuation.yield(RTCLinkVideoTrack(streamID: streamID, track: track))
    }
}
