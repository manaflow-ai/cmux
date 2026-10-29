import CmuxSafeConcurrency
import Foundation
import WebRTC

/// One peer connection with one ordered, reliable data channel (`rfb`) that
/// carries the RFB byte stream. The viewer offers and opens the channel; the
/// host answers. Every callback lands on libwebrtc's threads; state is behind
/// a lock and surfaced through `events`.
// Threads: libwebrtc's signaling thread calls the delegate methods; the owner's tasks negotiate, send and close. The
// lock is CmuxSafeConcurrency's `PlatformLock` beside the fields (the lock under its Mutex, for a type that keeps its
// state beside the lock), not a Mutex<State>: the guarded state holds libwebrtc objects (RTCDataChannel,
// RTCRtpSender, RTCRtpTransceiver, RTCIceCandidate), which its Objective-C SDK does not declare Sendable, so a value
// inside a Mutex<State> could not be handed out to the send and encode calls that use it after the lock is released.
// Those objects are proxies that marshal every call to libwebrtc's own threads (webrtc/pc/peer_connection_proxy.h,
// pc/rtp_sender_proxy.h).
// crash-allow: every mutable field is read and written only inside `lock.withLock` (threads and lock shape: above).
final class VNCPeerLink: NSObject, @unchecked Sendable, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    enum Event: Sendable {
        /// A local ICE candidate to send to the other side.
        case candidate(SignalMessage)
        case open
        case message(Data)
        case closed
        /// The ICE pair in use: each side's candidate type (host, srflx, prflx, relay).
        case path(local: String, remote: String)
        /// Viewer: the host's screen track arrived.
        case video(VideoTrackBox)
    }

    // One per process, made by Swift's one-time static initialization on whichever task first creates a link, then
    // never changed. No lock: nothing is written after init, and the factory marshals every call to its own signaling
    // thread (webrtc/api/peer_connection_factory_proxy.h). Unchecked only because the SDK does not declare it Sendable.
    // crash-allow: an immutable static `let` whose object is libwebrtc's thread-safe factory proxy: nothing to lock.
    nonisolated(unsafe) private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        // Hardware H.264 (VideoToolbox) first, then VP8/VP9/AV1 software; H.264 without a level frame rate cap.
        return RTCPeerConnectionFactory(encoderFactory: ScreenEncoderFactory(), decoderFactory: ScreenDecoderFactory())
    }()

    /// Largest data channel message (SCTP fragments larger ones less well).
    static let chunk = 16 * 1024
    /// Sends wait while the channel buffers more than this.
    static let highWater: UInt64 = 2 << 20

    let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation
    private let connection: RTCPeerConnection
    /// Where ``close()`` tears libwebrtc down: its close waits for the signaling thread.
    private let closeQueue = DispatchQueue(label: "cmux.vnc.peer-close", qos: .userInitiated)
    // concurrency-allow: held only to read or swap fields (no call into libwebrtc and no wait under it), so the signaling thread and the owner's tasks never block each other for longer than a field copy.
    private let lock = PlatformLock()
    private var channel: RTCDataChannel?
    private var remoteSet = false
    private var pending: [RTCIceCandidate] = []
    private var drained: [OnceContinuation<Void, OnceContinuationError>] = []
    private var ended = false
    private var videoTransceiver: RTCRtpTransceiver?
    /// The host's screen sender (its encoding parameters carry the quality).
    private var videoSender: RTCRtpSender?
    /// Secondary channels by label (the unordered `pointer` channel).
    private var extras: [String: RTCDataChannel] = [:]
    private var candidateErrorSink: (@Sendable (ICECandidateError) -> Void)?
    private var stallSink: (@Sendable (Bool) -> Void)?
    /// The connection stalled (ICE `disconnected`: no consent replies for a
    /// few seconds) or recovered (`connected`/`completed`). Any thread.
    var onStall: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { stallSink } }
        set { lock.withLock { stallSink = newValue } }
    }
    /// A STUN or TURN server could not give a candidate (WebRTC's
    /// `icecandidateerror`): a TURN 401 is refused credentials, 701 an
    /// unreachable server. Any thread.
    var onCandidateError: (@Sendable (ICECandidateError) -> Void)? {
        get { lock.withLock { candidateErrorSink } }
        set { lock.withLock { candidateErrorSink = newValue } }
    }

    /// `relayOnly` forces the TURN relay (measurements).
    /// `preferStreamRelays` (byte streams only) drops UDP TURN; video lets ICE choose.
    init(iceServers: [ICEServerConfig], relayOnly: Bool = false, preferStreamRelays: Bool = true) throws {
        (events, sink) = AsyncStream.makeStream(of: Event.self)
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.continualGatheringPolicy = .gatherContinually
        if relayOnly { configuration.iceTransportPolicy = .relay }
        configuration.iceServers = (preferStreamRelays ? VNCPeerLink.preferringStreamRelays(iceServers) : iceServers)
            .map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        // No delegate yet (self is not initialized): it is set right after, before any negotiation
        // starts, and libwebrtc reads the weak `delegate` at each callback.
        guard let connection = VNCPeerLink.factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else {
            throw VNCWebRTCError.peer("could not create a peer connection")
        }
        self.connection = connection
        super.init()
        connection.delegate = self
    }

    /// Drops UDP TURN when a TCP or TLS relay is offered. Measured on
    /// cmux-vnc-signal's Cloudflare TURN (two peers forced through the relay,
    /// 20 MB): UDP 1.8 MB/s or no path, TCP 3.1 MB/s, TLS 5.4-5.9 MB/s; relay
    /// loss on UDP collapses the data channel's SCTP congestion window.
    /// Direct paths (host and STUN candidates) are unaffected.
    static func preferringStreamRelays(_ servers: [ICEServerConfig]) -> [ICEServerConfig] {
        let hasStreamRelay = servers.contains { $0.urls.contains { $0.hasPrefix("turns:") || ($0.hasPrefix("turn:") && $0.contains("transport=tcp")) } }
        guard hasStreamRelay else { return servers }
        return servers.compactMap { server in
            var copy = server
            copy.urls = server.urls.filter { !($0.hasPrefix("turn:") && !$0.contains("transport=tcp")) }
            return copy.urls.isEmpty ? nil : copy
        }
    }

    // MARK: Negotiation

    /// Viewer: opens the data channel (`rfb` bytes, or `input` for a screen
    /// stream that also receives the host's video) and returns the offer SDP.
    func offer(label: String = "rfb", receiveVideo: Bool = false, unorderedLabel: String? = nil) async throws -> String {
        let configuration = RTCDataChannelConfiguration()
        configuration.isOrdered = true
        guard let created = connection.dataChannel(forLabel: label, configuration: configuration) else {
            throw VNCWebRTCError.peer("could not open the data channel")
        }
        adopt(created)
        if let unorderedLabel {
            // Pointer moves: latest wins, a lost one is never resent or waited for.
            let unordered = RTCDataChannelConfiguration()
            unordered.isOrdered = false
            unordered.maxRetransmits = 0
            if let extra = connection.dataChannel(forLabel: unorderedLabel, configuration: unordered) {
                extra.delegate = self
                lock.withLock { extras[unorderedLabel] = extra }
            }
        }
        if receiveVideo {
            let options = RTCRtpTransceiverInit()
            options.direction = .recvOnly
            if let transceiver = connection.addTransceiver(of: .video, init: options) {
                // H.264 first (hardware on Apple devices), through the standard API.
                let codecs = Self.factory.rtpReceiverCapabilities(forKind: "video").codecs
                let preferred = codecs.filter { $0.name == "H264" } + codecs.filter { $0.name != "H264" }
                Self.setCodecPreferences(transceiver, preferred)
                lock.withLock { videoTransceiver = transceiver }
            }
        }
        let sdp = try await describe { self.connection.offer(for: Self.constraints, completionHandler: $0) }
        try await apply { self.connection.setLocalDescription(RTCSessionDescription(type: .offer, sdp: sdp), completionHandler: $0) }
        return sdp
    }

    /// Host: answers a viewer's offer; `video` (a screen source) is sent on
    /// the viewer's receive-only video transceiver.
    func answer(offer sdp: String, video: ScreenVideoSource? = nil) async throws -> String {
        try await setRemote(RTCSessionDescription(type: .offer, sdp: sdp))
        if let video {
            let track = Self.factory.videoTrack(with: video.source, trackId: "screen")
            guard let sender = connection.add(track, streamIds: ["screen"]) else { throw VNCWebRTCError.peer("could not add the screen track") }
            lock.withLock { videoSender = sender }
            applyVideo(.auto, source: .zero)
        }
        let answer = try await describe { self.connection.answer(for: Self.constraints, completionHandler: $0) }
        try await apply { self.connection.setLocalDescription(RTCSessionDescription(type: .answer, sdp: answer), completionHandler: $0) }
        return answer
    }

    /// Host: the screen sender's encoding for `quality` of a `source`-sized
    /// display at `frameRate` (60 unless both displays agreed on more).
    /// These are WebRTC's own sender parameters; its congestion control keeps running.
    func applyVideo(_ quality: ScreenQuality, source: CGSize, frameRate: Int = ScreenQuality.baselineFrameRate) {
        guard let sender = lock.withLock({ videoSender }) else { return }
        let settings = quality.settings(sourceWidth: Int(source.width), sourceHeight: Int(source.height), frameRate: frameRate)
        let parameters = sender.parameters
        parameters.degradationPreference = NSNumber(value: settings.degradation.rawValue)
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: settings.maxBitrate)
            encoding.minBitrateBps = settings.minBitrate.map { NSNumber(value: $0) }
            encoding.maxFramerate = NSNumber(value: settings.maxFramerate)
            encoding.scaleResolutionDownBy = NSNumber(value: settings.scaleDown)
        }
        sender.parameters = parameters
    }

    /// Viewer: applies the host's answer.
    func accept(answer sdp: String) async throws {
        try await setRemote(RTCSessionDescription(type: .answer, sdp: sdp))
        // The receive-only transceiver's track (no didAdd callback for a transceiver this side created).
        if let track = lock.withLock({ videoTransceiver })?.receiver.track as? RTCVideoTrack {
            sink.yield(.video(VideoTrackBox(track: track)))
        }
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
        try await withOnceThrowingContinuation { (continuation: OnceContinuation<String, any Error>) in
            body { description, error in
                if let description { continuation.resume(returning: description.sdp) } else {
                    continuation.resume(throwing: VNCWebRTCError.peer(error?.localizedDescription ?? "no description"))
                }
            }
        }
    }

    private func apply(_ body: @escaping (@escaping ((any Error)?) -> Void) -> Void) async throws {
        try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
            body { error in
                if let error { continuation.resume(throwing: VNCWebRTCError.peer(error.localizedDescription)) } else { continuation.resume(returning: ()) }
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
                // A dropped waiter goes on as a drained one does: the loop checks `ended` and the buffer again.
                _ = try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
                    let resumeNow = lock.withLock { () -> Bool in
                        if ended || channel.bufferedAmount <= Self.highWater { return true }
                        drained.append(continuation)
                        return false
                    }
                    if resumeNow { continuation.resume(returning: ()) }
                }
                if lock.withLock({ ended }) { throw VNCWebRTCError.closed }
            }
            guard channel.sendData(RTCDataBuffer(data: data.subdata(in: offset ..< end), isBinary: true)) else {
                throw VNCWebRTCError.closed
            }
            offset = end
        }
    }

    /// A snapshot of the transport: the selected pair's RTT, the estimated
    /// send bandwidth, bytes each way, and the data channel's send backlog.
    struct Metrics: Sendable {
        var rttMs: Double?
        var availableOutgoingKbps: Double?
        var bytesSent: Double = 0
        var bytesReceived: Double = 0
        var backlogBytes: UInt64 = 0
    }

    func metrics() async -> Metrics {
        let backlog = lock.withLock { channel?.bufferedAmount ?? 0 }
        // No report (the statistics callback dropped) is the backlog alone.
        return (try? await withOnceContinuation { (continuation: OnceContinuation<Metrics, OnceContinuationError>) in
            connection.statistics { report in
                var metrics = Metrics(backlogBytes: backlog)
                for stats in report.statistics.values where stats.type == "candidate-pair" {
                    let values = stats.values
                    guard (values["nominated"] as? NSNumber)?.boolValue == true || (values["state"] as? String) == "succeeded" else { continue }
                    if let rtt = values["currentRoundTripTime"] as? NSNumber { metrics.rttMs = rtt.doubleValue * 1000 }
                    if let rate = values["availableOutgoingBitrate"] as? NSNumber { metrics.availableOutgoingKbps = rate.doubleValue / 1000 }
                    metrics.bytesSent = max(metrics.bytesSent, (values["bytesSent"] as? NSNumber)?.doubleValue ?? 0)
                    metrics.bytesReceived = max(metrics.bytesReceived, (values["bytesReceived"] as? NSNumber)?.doubleValue ?? 0)
                }
                continuation.resume(returning: metrics)
            }
        }) ?? Metrics(backlogBytes: backlog)
    }

    /// Ends the link at once (later sends fail, waiting sends resume) and returns; libwebrtc's own close runs on
    /// ``closeQueue``. That close waits for libwebrtc's signaling thread (the proxy marshals it there, and TURN
    /// deallocation can take seconds), so it never runs on the caller's thread: the main thread, a pool thread or a
    /// libwebrtc callback, which must not close the connection it is called from. Chrome posts a peer connection's
    /// close to its signaling thread the same way (pc/peer_connection_proxy.h).
    func close() {
        let (waiters, first) = lock.withLock { () -> ([OnceContinuation<Void, OnceContinuationError>], Bool) in
            let waiters = drained
            drained.removeAll()
            defer { ended = true }
            return (waiters, !ended)
        }
        guard first else { return }
        for waiter in waiters { waiter.resume(returning: ()) }
        closeQueue.async { [self] in
            lock.withLock { channel }?.close()
            connection.close()
            finish()
        }
    }

    /// Sends `text` on the primary channel, then closes the link once `drain` has passed, so SCTP sends the queued
    /// text before the connection closes (closing at once can discard it); closes at once when the text cannot be
    /// sent. Returns at once: the send (a call the channel proxy marshals to libwebrtc's signaling thread) and the
    /// close run on ``closeQueue``.
    func close(sendingFirst text: String, drain: DispatchTimeInterval) {
        closeQueue.async { [self] in
            guard sendText(text) else {
                close()
                return
            }
            closeQueue.asyncAfter(deadline: .now() + drain) { [self] in close() }
        }
    }

    /// Text messages on the data channel (screen stream control and input).
    func sendText(_ text: String, on label: String? = nil) -> Bool {
        let target = lock.withLock { label.flatMap { extras[$0] } ?? channel }
        guard let channel = target, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
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
        guard lock.withLock({ dataChannel === channel }) else { return }
        switch dataChannel.readyState {
        case .open: sink.yield(.open)
        case .closed: close()
        default: break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        sink.yield(.message(buffer.data))
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        guard dataChannel.bufferedAmount <= Self.highWater else { return }
        let waiters = lock.withLock { () -> [OnceContinuation<Void, OnceContinuationError>] in
            defer { drained.removeAll() }
            return drained
        }
        for waiter in waiters { waiter.resume(returning: ()) }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .closed { close() }
        switch newState {
        case .disconnected: onStall?(true)
        case .connected, .completed: onStall?(false)
        default: break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent) {
        onCandidateError?(ICECandidateError(code: Int(event.errorCode), url: event.url, text: event.errorText))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        sink.yield(.candidate(SignalMessage(type: "candidate", candidate: candidate.sdp, sdpMid: candidate.sdpMid,
                                            sdpMLineIndex: candidate.sdpMLineIndex)))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate local: RTCIceCandidate,
                        remoteCandidate remote: RTCIceCandidate, lastReceivedMs lastDataReceivedMs: Int32, changeReason reason: String) {
        sink.yield(.path(local: Self.type(of: local.sdp), remote: Self.type(of: remote.sdp)))
    }

    /// `typ host|srflx|prflx|relay` from a candidate line.
    static func type(of sdp: String) -> String {
        let parts = sdp.split(separator: " ")
        guard let index = parts.firstIndex(of: "typ"), index + 1 < parts.count else { return "unknown" }
        return String(parts[index + 1])
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        // Reported once, from accept(answer:), for the viewer's own transceiver.
        guard lock.withLock({ videoTransceiver == nil }), let track = rtpReceiver.track as? RTCVideoTrack else { return }
        sink.yield(.video(VideoTrackBox(track: track)))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Host side: the viewer's channels; the ordered one (not `pointer`) is primary.
        let isPrimary = lock.withLock { () -> Bool in
            guard dataChannel.label == "pointer" || channel != nil else { return true }
            extras[dataChannel.label] = dataChannel
            return false
        }
        if isPrimary { adopt(dataChannel) } else { dataChannel.delegate = self }
    }
}

/// The host's screen as a WebRTC video source. Frames are pushed by
/// `ScreenStreamHost`; libwebrtc encodes (hardware H.264), paces and adapts.
// Threads: `push` runs on the capture source's thread (ScreenCaptureKit's sample-handler queue or the VNC frames task)
// and on the host's idle-refresh task, sometimes at once. `deliver` serializes them: libwebrtc's ObjC source
// (sdk/objc/native/src/objc_video_track_source.mm, OnCapturedFrame) runs its TimestampAligner before the adapter's and
// the broadcaster's own mutexes, and rtc_base/timestamp_aligner.h requires external synchronization. Unchecked only
// because the SDK does not declare RTCVideoSource or RTCVideoCapturer Sendable, so a Mutex cannot hold them.
// crash-allow: two immutable `let`s, and every call into them goes through `deliver`, which serializes it.
public final class ScreenVideoSource: @unchecked Sendable {
    let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    // concurrency-allow: held only for one OnCapturedFrame call (timestamp translation, adapt, hand-off to the encoder queue), never across a wait, so a capture thread and the idle-refresh task never deliver at once (lock carve-out).
    private let deliver = Mutex(())

    init() {
        source = VNCPeerLink.makeScreenSource()
        capturer = RTCVideoCapturer(delegate: source)
    }

    /// Sends `crop` of `pixelBuffer` (32BGRA or NV12) as the next frame.
    func push(_ pixelBuffer: CVPixelBuffer, crop: CGRect, timestampNs: Int64) {
        let x = Int32(crop.minX) & ~1, y = Int32(crop.minY) & ~1
        let width = Int32(crop.width) & ~1, height = Int32(crop.height) & ~1
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer, adaptedWidth: width, adaptedHeight: height,
                                      cropWidth: width, cropHeight: height, cropX: x, cropY: y)
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timestampNs)
        deliver.withLock { _ in source.capturer(capturer, didCapture: frame) }
    }
}

/// A received video track.
// Threads: made on libwebrtc's signaling thread (a delegate callback) or the viewer's negotiate task, handed through
// `events` to the app, which adds renderers on the main thread. No lock: the box is immutable, and the track is a proxy
// that marshals each call to libwebrtc's own thread (webrtc/api/media_stream_track_proxy.h). Unchecked only because
// the SDK does not declare RTCVideoTrack Sendable.
// crash-allow: one immutable `let` to libwebrtc's thread-safe track proxy: nothing to lock.
public struct VideoTrackBox: @unchecked Sendable {
    public let track: RTCVideoTrack
}

extension VNCPeerLink {
    /// `setCodecPreferences:error:` (the non-deprecated form; Swift otherwise
    /// resolves the deprecated overload, which does not apply the order).
    static func setCodecPreferences(_ transceiver: RTCRtpTransceiver, _ codecs: [RTCRtpCodecCapability]) {
        // crash-allow: checked with responds(to:) before the call, so an unknown selector returns instead of raising.
        let selector = NSSelectorFromString("setCodecPreferences:error:")
        guard transceiver.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, NSArray, UnsafeMutablePointer<NSError?>?) -> Bool
        // SAFETY: responds(to:) above proves the IMP exists, and Setter is the C signature of
        // -[RTCRtpTransceiver setCodecPreferences:error:] (id self, SEL, NSArray *, NSError **)
        // returning BOOL, so the cast IMP is called with the types it was compiled for.
        let method = unsafe unsafeBitCast(transceiver.method(for: selector), to: Setter.self)
        // SAFETY: the IMP's own signature (above); a nil error pointer is allowed by the
        // method and makes it write nothing back.
        _ = unsafe method(transceiver, selector, codecs as NSArray, nil)
    }

    /// Receive codec names, in the factory's order (diagnostics).
    static func receiveCodecNames() -> [String] { factory.rtpReceiverCapabilities(forKind: "video").codecs.map(\.name) }

    static func makeScreenSource() -> RTCVideoSource { factory.videoSource(forScreenCast: true) }
}

extension VNCPeerLink {
    /// Inbound video numbers for the viewer's overlay.
    /// Empty stats when the statistics callback dropped without a report.
    func videoStats() async -> ScreenStreamViewer.VideoStats {
        (try? await withOnceContinuation { (continuation: OnceContinuation<ScreenStreamViewer.VideoStats, OnceContinuationError>) in
            connection.statistics { report in
                var stats = ScreenStreamViewer.VideoStats()
                var codecs: [String: String] = [:]
                for entry in report.statistics.values where entry.type == "codec" {
                    codecs[entry.id] = (entry.values["mimeType"] as? String)?.replacingOccurrences(of: "video/", with: "")
                }
                for entry in report.statistics.values {
                    let values = entry.values
                    if entry.type == "inbound-rtp", (values["kind"] as? String) == "video" {
                        stats.fps = (values["framesPerSecond"] as? NSNumber)?.doubleValue
                        stats.bytesReceived = (values["bytesReceived"] as? NSNumber)?.doubleValue ?? 0
                        stats.framesDecoded = (values["framesDecoded"] as? NSNumber)?.doubleValue ?? 0
                        stats.framesReceived = (values["framesReceived"] as? NSNumber)?.doubleValue ?? 0
                        stats.framesDropped = (values["framesDropped"] as? NSNumber)?.doubleValue ?? 0
                        stats.totalDecodeTime = (values["totalDecodeTime"] as? NSNumber)?.doubleValue ?? 0
                        stats.freezeCount = (values["freezeCount"] as? NSNumber)?.doubleValue ?? 0
                        stats.packetsLost = (values["packetsLost"] as? NSNumber)?.doubleValue ?? 0
                        if let delay = (values["jitterBufferDelay"] as? NSNumber)?.doubleValue,
                           let emitted = (values["jitterBufferEmittedCount"] as? NSNumber)?.doubleValue, emitted > 0 {
                            stats.jitterBufferMs = delay / emitted * 1000
                        }
                        if let codec = values["codecId"] as? String { stats.codec = codecs[codec] }
                        stats.decoder = values["decoderImplementation"] as? String
                    }
                    if entry.type == "candidate-pair", (values["nominated"] as? NSNumber)?.boolValue == true,
                       let rtt = values["currentRoundTripTime"] as? NSNumber {
                        stats.rttMs = rtt.doubleValue * 1000
                    }
                }
                continuation.resume(returning: stats)
            }
        }) ?? ScreenStreamViewer.VideoStats()
    }
}

extension VNCPeerLink {
    /// Outbound video, one line (host diagnostics): the frames reaching the
    /// encoder (`source fps`), the encoder's output and what limits it, and
    /// the round trip.
    func outboundVideoSummary() async -> String {
        (try? await withOnceContinuation { (continuation: OnceContinuation<String, OnceContinuationError>) in
            connection.statistics { report in
                var codecs: [String: String?] = [:]
                for entry in report.statistics.values where entry.type == "codec" {
                    codecs[entry.id] = entry.values["mimeType"] as? String
                }
                var sourceFps = "?"
                for entry in report.statistics.values where entry.type == "media-source" && (entry.values["kind"] as? String) == "video" {
                    sourceFps = entry.values["framesPerSecond"].map { "\($0)" } ?? "?"
                }
                var rtt = "?"
                for entry in report.statistics.values where entry.type == "candidate-pair" && (entry.values["nominated"] as? NSNumber)?.boolValue == true {
                    if let seconds = entry.values["currentRoundTripTime"] as? NSNumber { rtt = String(format: "%.1f", seconds.doubleValue * 1000) }
                }
                var out = "no outbound video"
                for entry in report.statistics.values where entry.type == "outbound-rtp" && (entry.values["kind"] as? String) == "video" {
                    let v = entry.values
                    func f(_ key: String) -> String { v[key].map { "\($0)" } ?? "?" }
                    let codec = codecs[(v["codecId"] as? String) ?? ""].flatMap { $0 } ?? "?"
                    let encodeMs = (v["totalEncodeTime"] as? NSNumber).flatMap { total in
                        (v["framesEncoded"] as? NSNumber).map { $0.doubleValue > 0 ? total.doubleValue / $0.doubleValue * 1000 : 0 }
                    }.map { String(format: "%.2f", $0) } ?? "?"
                    out = "codec \(codec) encoder \(f("encoderImplementation")) powerEfficient \(f("powerEfficientEncoder")) \(f("frameWidth"))x\(f("frameHeight")) source fps \(sourceFps) fps \(f("framesPerSecond")) encoded \(f("framesEncoded")) sent \(f("framesSent")) encode \(encodeMs) ms limited-by \(f("qualityLimitationReason")) target \(f("targetBitrate")) bps sent-bytes \(f("bytesSent")) rtt \(rtt) ms"
                }
                continuation.resume(returning: out)
            }
        }) ?? "no outbound video"
    }
}

/// The default decoders, with H.264 declared at level 5.2 instead of the
/// default 3.1 (a 1080p frame does not fit level 3.1, so the sender's
/// hardware encoder fails setup and falls back to software VP8). Apple's
/// hardware decodes level 5.2; this states it through the factory API.
final class ScreenDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let base = RTCDefaultVideoDecoderFactory()

    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        base.createDecoder(info)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        base.supportedCodecs().map { info in
            guard info.name == "H264", let level = info.parameters["profile-level-id"] else { return info }
            var parameters = info.parameters
            parameters["profile-level-id"] = String(level.prefix(4)) + "34"
            return RTCVideoCodecInfo(name: info.name, parameters: parameters)
        }
    }
}
