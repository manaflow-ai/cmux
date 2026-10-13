import Foundation
import WebRTC

/// One peer connection with one ordered, reliable data channel (`rfb`) that
/// carries the RFB byte stream. The viewer offers and opens the channel; the
/// host answers. Every callback lands on libwebrtc's threads; state is behind
/// a lock and surfaced through `events`.
final class VNCPeerLink: NSObject, @unchecked Sendable, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    enum Event: Sendable {
        /// A local ICE candidate to send to the other side.
        case candidate(SignalMessage)
        case open
        case message(Data)
        case closed
    }

    // libwebrtc's factory is thread-safe and owns its threads; one per process.
    nonisolated(unsafe) private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    /// Largest data channel message (SCTP fragments larger ones less well).
    static let chunk = 16 * 1024
    /// Sends wait while the channel buffers more than this.
    static let highWater: UInt64 = 2 << 20

    let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation
    private var connection: RTCPeerConnection!
    private let lock = NSLock()
    private var channel: RTCDataChannel?
    private var remoteSet = false
    private var pending: [RTCIceCandidate] = []
    private var drained: [CheckedContinuation<Void, Never>] = []
    private var ended = false

    init(iceServers: [ICEServerConfig]) throws {
        (events, sink) = AsyncStream.makeStream(of: Event.self)
        super.init()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceServers = iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw VNCWebRTCError.peer("could not create a peer connection")
        }
        self.connection = connection
    }

    // MARK: Negotiation

    /// Viewer: opens the `rfb` channel and returns the offer SDP.
    func offer() async throws -> String {
        let configuration = RTCDataChannelConfiguration()
        configuration.isOrdered = true
        guard let created = connection.dataChannel(forLabel: "rfb", configuration: configuration) else {
            throw VNCWebRTCError.peer("could not open the data channel")
        }
        adopt(created)
        let sdp = try await describe { self.connection.offer(for: Self.constraints, completionHandler: $0) }
        try await apply { self.connection.setLocalDescription(RTCSessionDescription(type: .offer, sdp: sdp), completionHandler: $0) }
        return sdp
    }

    /// Host: answers a viewer's offer.
    func answer(offer sdp: String) async throws -> String {
        try await setRemote(RTCSessionDescription(type: .offer, sdp: sdp))
        let answer = try await describe { self.connection.answer(for: Self.constraints, completionHandler: $0) }
        try await apply { self.connection.setLocalDescription(RTCSessionDescription(type: .answer, sdp: answer), completionHandler: $0) }
        return answer
    }

    /// Viewer: applies the host's answer.
    func accept(answer sdp: String) async throws {
        try await setRemote(RTCSessionDescription(type: .answer, sdp: sdp))
    }

    /// A remote candidate; held until the remote description is set.
    func add(candidate message: SignalMessage) async {
        guard let sdp = message.candidate else { return }
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: message.sdpMLineIndex ?? 0, sdpMid: message.sdpMid)
        let ready = lock.withLock { () -> Bool in
            if !remoteSet { pending.append(candidate) }
            return remoteSet
        }
        if ready { try? await apply { self.connection.add(candidate, completionHandler: $0) } }
    }

    private func setRemote(_ description: RTCSessionDescription) async throws {
        try await apply { self.connection.setRemoteDescription(description, completionHandler: $0) }
        let queued = lock.withLock { () -> [RTCIceCandidate] in
            remoteSet = true
            defer { pending.removeAll() }
            return pending
        }
        for candidate in queued { try? await apply { self.connection.add(candidate, completionHandler: $0) } }
    }

    private static var constraints: RTCMediaConstraints { RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil) }

    /// The SDP text of a created offer or answer (the description object is not Sendable).
    private func describe(_ body: @escaping (@escaping (RTCSessionDescription?, (any Error)?) -> Void) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            body { description, error in
                if let description { continuation.resume(returning: description.sdp) } else {
                    continuation.resume(throwing: VNCWebRTCError.peer(error?.localizedDescription ?? "no description"))
                }
            }
        }
    }

    private func apply(_ body: @escaping (@escaping ((any Error)?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            body { error in
                if let error { continuation.resume(throwing: VNCWebRTCError.peer(error.localizedDescription)) } else { continuation.resume() }
            }
        }
    }

    // MARK: Data

    /// Sends `data` in order, waiting while the channel's buffer is full.
    func send(_ data: Data) async throws {
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.chunk, data.count)
            guard let channel = lock.withLock({ channel }), channel.readyState == .open else { throw VNCWebRTCError.closed }
            while channel.bufferedAmount > Self.highWater {
                await withCheckedContinuation { continuation in
                    let resumeNow = lock.withLock { () -> Bool in
                        if ended || channel.bufferedAmount <= Self.highWater { return true }
                        drained.append(continuation)
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
                if lock.withLock({ ended }) { throw VNCWebRTCError.closed }
            }
            guard channel.sendData(RTCDataBuffer(data: data.subdata(in: offset ..< end), isBinary: true)) else {
                throw VNCWebRTCError.closed
            }
            offset = end
        }
    }

    func close() {
        let (channel, waiters, first) = lock.withLock { () -> (RTCDataChannel?, [CheckedContinuation<Void, Never>], Bool) in
            let waiters = drained
            drained.removeAll()
            defer { ended = true }
            return (self.channel, waiters, !ended)
        }
        guard first else { return }
        for waiter in waiters { waiter.resume() }
        channel?.close()
        connection.close()
        finish()
    }

    /// libwebrtc must not be closed from inside its own callbacks (signaling thread).
    private func closeOffCallback() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in close() }
    }

    private func adopt(_ channel: RTCDataChannel) {
        channel.delegate = self
        lock.withLock { self.channel = channel }
        if channel.readyState == .open { sink.yield(.open) }
    }

    private func finish() {
        sink.yield(.closed)
        sink.finish()
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open: sink.yield(.open)
        case .closed: closeOffCallback()
        default: break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        sink.yield(.message(buffer.data))
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        guard dataChannel.bufferedAmount <= Self.highWater else { return }
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { drained.removeAll() }
            return drained
        }
        for waiter in waiters { waiter.resume() }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .closed { closeOffCallback() }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        sink.yield(.candidate(SignalMessage(type: "candidate", candidate: candidate.sdp, sdpMid: candidate.sdpMid,
                                            sdpMLineIndex: candidate.sdpMLineIndex)))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Host side: the viewer's channel.
        adopt(dataChannel)
    }
}
