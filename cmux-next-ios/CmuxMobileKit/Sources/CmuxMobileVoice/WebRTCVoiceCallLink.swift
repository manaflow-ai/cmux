#if os(iOS)
import AVFoundation
public import CmuxMobileRealtime
import Foundation
import OSLog
import WebRTC

private let log = Logger(subsystem: "dev.cmux.mobile", category: "chief-call")

/// A Chief call's connection to the Realtime API over WebRTC: the
/// microphone as an audio track, Chief's voice as the remote track (played
/// by libwebrtc with the system's echo cancellation), and JSON events on the
/// `oai-events` data channel. Signaling is one HTTPS request
/// (``RealtimeCallsAPI``); there is no ICE trickle.
@MainActor
public final class WebRTCVoiceCallLink: VoiceCallLink {
    public let events: AsyncStream<VoiceCallLinkEvent>
    private let sink: AsyncStream<VoiceCallLinkEvent>.Continuation
    private let api: RealtimeCallsAPI
    private let apiKey: String
    private let safetyIdentifier: String?
    private var peer: Peer?
    private var interruptionObserver: (any NSObjectProtocol)?
    private var speaker = true
    private var microphoneEnabled = true
    private var isClosed = false

    /// - Parameters:
    ///   - apiKey: The user's key, read from the Keychain for this call only.
    ///   - safetyIdentifier: A hash of the cmux account.
    public init(apiKey: String, safetyIdentifier: String?, api: RealtimeCallsAPI = RealtimeCallsAPI()) {
        (events, sink) = AsyncStream.makeStream(of: VoiceCallLinkEvent.self)
        self.apiKey = apiKey
        self.safetyIdentifier = safetyIdentifier
        self.api = api
    }

    public func open(session: Data) async throws {
        peer?.close()
        peer = nil
        guard !isClosed else { throw CancellationError() }
        try configureAudioSession()
        let peer = try Peer(sink: sink)
        peer.setMicrophoneEnabled(microphoneEnabled)
        self.peer = peer
        let offer = try await peer.offer()
        let answer = try await api.connect(offerSDP: offer, session: session, apiKey: apiKey, safetyIdentifier: safetyIdentifier)
        try await peer.accept(answer: answer)
        try await peer.waitUntilOpen()
        // Hung up while connecting: close() already ran; leave nothing behind.
        guard !isClosed else { throw CancellationError() }
        observeInterruptions()
        log.info("chief call connected")
    }

    public func send(_ data: Data) {
        peer?.send(data)
    }

    public func setMicrophoneEnabled(_ enabled: Bool) {
        microphoneEnabled = enabled
        peer?.setMicrophoneEnabled(enabled)
    }

    public func setSpeakerOutput(_ speaker: Bool) {
        self.speaker = speaker
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do { try session.overrideOutputAudioPort(speaker ? .speaker : .none) } catch {
            log.error("speaker route: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func close() {
        isClosed = true
        peer?.close()
        peer = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setActive(false)
        session.unlockForConfiguration()
        sink.finish()
    }

    /// Voice chat: the voice-processing I/O unit (echo cancellation, so
    /// Chief doesn't hear itself on the speaker), Bluetooth headsets, and the
    /// speaker by default (held like a voice assistant, not to the ear). The
    /// speaker is a port override, not `.defaultToSpeaker`, so turning it off
    /// moves the audio to the earpiece.
    private func configureAudioSession() throws {
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = false
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        configuration.categoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
        do {
            try session.setConfiguration(configuration, active: true)
            try session.overrideOutputAudioPort(speaker ? .speaker : .none)
        } catch {
            throw VoiceCallFailure.network(String(localized: "The microphone couldn't start: \(error.localizedDescription)"))
        }
    }

    /// A phone call or Siri takes the audio: the call holds (microphone off) until it gives it back.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        let sink = sink
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            sink.yield(.audioInterrupted(type == .began))
        }
    }
}

/// The peer connection and its data channel. libwebrtc calls the delegate
/// on its own threads; state is behind a lock and leaves through `sink`.
// crash-allow: mutable state (channel, open waiters) is read and written only under `lock`; libwebrtc objects are thread-safe.
private final class Peer: NSObject, @unchecked Sendable, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    // crash-allow: a `let` made once (lazy static init is atomic); libwebrtc's factory is thread-safe.
    nonisolated(unsafe) private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private let sink: AsyncStream<VoiceCallLinkEvent>.Continuation
    private let connection: RTCPeerConnection
    private let microphone: RTCAudioTrack
    private let lock = NSLock()
    private var channel: RTCDataChannel?
    private var isOpen = false
    private var openWaiters: [CheckedContinuation<Void, any Error>] = []
    private var closed = false

    init(sink: AsyncStream<VoiceCallLinkEvent>.Continuation) throws {
        self.sink = sink
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Peer.factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else {
            throw VoiceCallFailure.network(String(localized: "The audio connection couldn't be set up."))
        }
        self.connection = connection
        let source = Peer.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        microphone = Peer.factory.audioTrack(with: source, trackId: "microphone")
        super.init()
        connection.delegate = self
        // Send the microphone, receive Chief's voice.
        connection.add(microphone, streamIds: ["chief-call"])
        let channelConfiguration = RTCDataChannelConfiguration()
        channelConfiguration.isOrdered = true
        guard let channel = connection.dataChannel(forLabel: "oai-events", configuration: channelConfiguration) else {
            throw VoiceCallFailure.network(String(localized: "The audio connection couldn't be set up."))
        }
        channel.delegate = self
        lock.withLock { self.channel = channel }
    }

    func offer() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)
        let sdp: String = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description.sdp) } else {
                    continuation.resume(throwing: VoiceCallFailure.network(error?.localizedDescription ?? "no offer"))
                }
            }
        }
        try await apply { self.connection.setLocalDescription(RTCSessionDescription(type: .offer, sdp: sdp), completionHandler: $0) }
        return sdp
    }

    func accept(answer: String) async throws {
        try await apply { self.connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer), completionHandler: $0) }
    }

    /// Returns once the data channel opens; throws if the connection fails first.
    func waitUntilOpen() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumeNow: Result<Void, any Error>? = lock.withLock {
                if isOpen { return .success(()) }
                if closed { return .failure(VoiceCallFailure.network(String(localized: "The audio connection failed."))) }
                openWaiters.append(continuation)
                return nil
            }
            if let resumeNow { continuation.resume(with: resumeNow) }
        }
    }

    func send(_ data: Data) {
        guard let channel = lock.withLock({ channel }), channel.readyState == .open else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        microphone.isEnabled = enabled
    }

    func close() {
        let (channel, waiters) = lock.withLock { () -> (RTCDataChannel?, [CheckedContinuation<Void, any Error>]) in
            closed = true
            defer { openWaiters.removeAll(); self.channel = nil }
            return (self.channel, openWaiters)
        }
        channel?.delegate = nil
        channel?.close()
        connection.delegate = nil
        connection.close()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }

    private func apply(_ body: @escaping (@escaping ((any Error)?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            body { error in
                if let error { continuation.resume(throwing: VoiceCallFailure.network(error.localizedDescription)) } else {
                    continuation.resume()
                }
            }
        }
    }

    /// The connection ended under the call: wake an open wait, tell the call.
    private func ended() {
        let (wasClosed, waiters) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, any Error>]) in
            let was = closed
            closed = true
            defer { openWaiters.removeAll() }
            return (was, openWaiters)
        }
        for waiter in waiters { waiter.resume(throwing: VoiceCallFailure.network(String(localized: "The audio connection failed."))) }
        if !wasClosed { sink.yield(.closed) }
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                isOpen = true
                defer { openWaiters.removeAll() }
                return openWaiters
            }
            for waiter in waiters { waiter.resume() }
        case .closed:
            ended()
        default:
            break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        sink.yield(.message(buffer.data))
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .closed { ended() }
    }
}
#endif
