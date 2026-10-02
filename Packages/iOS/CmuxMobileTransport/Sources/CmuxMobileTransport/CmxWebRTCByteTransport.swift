@preconcurrency import WebRTC
public import CMUXMobileCore
public import Foundation

/// Errors raised by the experimental WebRTC byte transport.
public enum CmxWebRTCByteTransportError: Error, Equatable, Sendable {
    /// The route URL is missing a host, port, or signaling token.
    case invalidRoute
    /// The route authorization mode is not valid for a WebRTC control session.
    case unsupportedAuthorizationMode(CmxTransportAuthorizationMode)
    /// The peer connection was not ready for the requested operation.
    case notConnected
    /// The peer connection has been closed.
    case alreadyClosed
    /// The signaling or data-channel deadline elapsed.
    case timedOut
    /// The native peer connection could not be created.
    case peerConnectionUnavailable
    /// The native data channel rejected a write.
    case sendFailed
    /// The peer closed or failed while receiving.
    case receiveFailed(String)
    /// A native WebRTC operation returned an error.
    case operationFailed(String)
    /// The authenticated ICE server provider returned no usable servers.
    case iceServersUnavailable
    /// The peer sent an unexpected signaling message.
    case unexpectedSignal
}

private final class CmxWebRTCSessionDescriptionBox: @unchecked Sendable {
    // Safety: the native description is created by WebRTC and read only on the
    // owning transport actor after the callback wraps it in this box.
    let value: RTCSessionDescription

    init(_ value: RTCSessionDescription) {
        self.value = value
    }
}

private final class CmxWebRTCDataChannelBox: @unchecked Sendable {
    // Safety: WebRTC data-channel calls are serialized by the owning transport
    // actor; the delegate only forwards this reference through an immutable box.
    let value: RTCDataChannel

    init(_ value: RTCDataChannel) {
        self.value = value
    }
}

private enum CmxWebRTCPeerEvent: Sendable {
    case candidate(CmxWebRTCCandidate)
    case dataChannel(CmxWebRTCDataChannelBox)
    case dataChannelState(Int)
    case data(Data)
    case connectionState(Int)
}

/// Bridges Objective-C WebRTC callbacks into the owning transport actor.
///
/// The bridge is intentionally a tiny callback adapter. It does not retain
/// mutable transport state and never performs application work on WebRTC's
/// callback queue.
private final class CmxWebRTCPeerDelegate: NSObject, @unchecked Sendable,
    RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private let emit: @Sendable (CmxWebRTCPeerEvent) -> Void

    init(emit: @escaping @Sendable (CmxWebRTCPeerEvent) -> Void) {
        self.emit = emit
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        emit(.candidate(CmxWebRTCCandidate(
            sdp: candidate.sdp,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )))
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {
        emit(.dataChannel(CmxWebRTCDataChannelBox(dataChannel)))
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        emit(.connectionState(newState.rawValue))
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        emit(.dataChannelState(dataChannel.readyState.rawValue))
    }

    func dataChannel(
        _ dataChannel: RTCDataChannel,
        didReceiveMessageWith buffer: RTCDataBuffer
    ) {
        emit(.data(Data(buffer.data)))
    }
}

/// An ordered, reliable WebRTC data channel exposed through cmux's byte-transport protocol.
public actor CmxWebRTCByteTransport: CmxByteTransport {
    private static let dataChannelLabel = "cmux-control"

    private enum State {
        case idle
        case negotiating
        case ready
        case failed(CmxWebRTCByteTransportError)
        case closed
    }

    private let configuration: CmxWebRTCConfiguration
    private let clientHost: String?
    private let clientPort: Int?
    private let clientRelayURL: URL?
    private let signalingToken: String?
    private let signalingAccessTokenProvider: CmxWebRTITokenProvider?
    private let iceServersProvider: CmxWebRTCIceServersProvider?
    private var signaling: CmxWebRTCSignalingConnection?
    private var state: State = .idle
    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var peerDelegate: CmxWebRTCPeerDelegate?
    private var signalReaderTask: Task<Void, Never>?
    private var remoteDescriptionSet = false
    private var pendingRemoteCandidates: [CmxWebRTCCandidate] = []
    private var receiveBuffer: [Data] = []
    private var receiveContinuation: CheckedContinuation<Data?, any Error>?
    private var readyContinuations: [UUID: CheckedContinuation<Void, any Error>] = [:]

    /// Creates an iOS-side client transport from a signaling endpoint.
    ///
    /// - Parameters:
    ///   - host: The Mac host used for TCP signaling.
    ///   - port: The signaling TCP port.
    ///   - token: The per-listener signaling token.
    ///   - configuration: ICE and timeout configuration.
    /// - Throws: ``CmxWebRTCByteTransportError/invalidRoute`` for invalid values.
    init(
        clientHost host: String,
        clientPort port: Int,
        token: String,
        configuration: CmxWebRTCConfiguration,
        iceServersProvider: CmxWebRTCIceServersProvider? = nil,
        signalingAccessTokenProvider: CmxWebRTITokenProvider? = nil
    ) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65535).contains(port),
              !token.isEmpty else {
            throw CmxWebRTCByteTransportError.invalidRoute
        }
        self.configuration = configuration
        self.clientHost = host
        self.clientPort = port
        clientRelayURL = nil
        self.signalingToken = token
        self.signalingAccessTokenProvider = signalingAccessTokenProvider
        self.iceServersProvider = iceServersProvider
    }

    /// Creates a client transport that uses the authenticated public signaling
    /// relay. The route token is a per-listener capability; Stack credentials
    /// authenticate the account at the relay before it is paired.
    init(
        clientRelayURL relayURL: URL,
        token: String,
        configuration: CmxWebRTCConfiguration,
        iceServersProvider: CmxWebRTCIceServersProvider? = nil,
        signalingAccessTokenProvider: CmxWebRTITokenProvider?
    ) throws {
        guard !token.isEmpty else { throw CmxWebRTCByteTransportError.invalidRoute }
        self.configuration = configuration
        clientHost = nil
        clientPort = nil
        clientRelayURL = relayURL
        signalingToken = token
        self.signalingAccessTokenProvider = signalingAccessTokenProvider
        self.iceServersProvider = iceServersProvider
    }

    /// Creates a host-side transport around an already-authenticated signaling socket.
    ///
    /// - Parameters:
    ///   - signaling: A ready signaling connection after token validation.
    ///   - configuration: ICE and timeout configuration.
    init(
        hostSignaling signaling: CmxWebRTCSignalingConnection,
        configuration: CmxWebRTCConfiguration,
        iceServersProvider: CmxWebRTCIceServersProvider? = nil
    ) {
        self.configuration = configuration
        clientHost = nil
        clientPort = nil
        clientRelayURL = nil
        signalingToken = nil
        signalingAccessTokenProvider = nil
        self.iceServersProvider = iceServersProvider
        self.signaling = signaling
    }

    /// Connects the client or waits for an accepted host data channel.
    ///
    /// - Throws: ``CmxWebRTCByteTransportError`` when signaling, ICE, or the
    ///   data channel cannot become ready.
    public func connect() async throws {
        switch state {
        case .ready:
            return
        case .closed:
            throw CmxWebRTCByteTransportError.alreadyClosed
        case let .failed(error):
            throw error
        case .negotiating:
            try await waitUntilReady()
            return
        case .idle:
            break
        }

        state = .negotiating
        if let clientRelayURL, let signalingToken {
            guard let signalingAccessTokenProvider else {
                throw CmxWebRTCByteTransportError.invalidRoute
            }
            let tokens: (accessToken: String, refreshToken: String?)
            do {
                tokens = try await signalingAccessTokenProvider()
            } catch {
                throw CmxWebRTCByteTransportError.operationFailed("signaling authentication unavailable")
            }
            signaling = try await CmxWebRTCSignalingConnection.connectWebSocket(
                url: clientRelayURL,
                role: "client",
                routeToken: signalingToken,
                tokens: tokens
            )
            guard let signaling else { throw CmxWebRTCByteTransportError.invalidRoute }
            try await signaling.send(.hello(token: signalingToken))
            try await createPeerConnection()
            startSignalReader()
            guard let peerConnection else {
                throw CmxWebRTCByteTransportError.peerConnectionUnavailable
            }
            let dataConfiguration = RTCDataChannelConfiguration()
            dataConfiguration.isOrdered = true
            guard let channel = peerConnection.dataChannel(
                forLabel: Self.dataChannelLabel,
                configuration: dataConfiguration
            ) else {
                throw CmxWebRTCByteTransportError.peerConnectionUnavailable
            }
            channel.delegate = peerDelegate
            dataChannel = channel
            let offer = try await createOffer()
            try await setLocalDescription(offer)
            try await signaling.send(.offer(sdp: offer.value.sdp))
        } else if let clientHost, let clientPort, let signalingToken {
            signaling = try await CmxWebRTCSignalingConnection.connect(
                host: clientHost,
                port: clientPort,
                timeoutNanoseconds: configuration.signalingTimeoutNanoseconds
            )
            guard let signaling else { throw CmxWebRTCByteTransportError.invalidRoute }
            try await signaling.send(.hello(token: signalingToken))
            try await createPeerConnection()
            startSignalReader()
            guard let peerConnection else {
                throw CmxWebRTCByteTransportError.peerConnectionUnavailable
            }
            let dataConfiguration = RTCDataChannelConfiguration()
            dataConfiguration.isOrdered = true
            guard let channel = peerConnection.dataChannel(
                forLabel: Self.dataChannelLabel,
                configuration: dataConfiguration
            ) else {
                throw CmxWebRTCByteTransportError.peerConnectionUnavailable
            }
            channel.delegate = peerDelegate
            dataChannel = channel
            let offer = try await createOffer()
            try await setLocalDescription(offer)
            try await signaling.send(.offer(sdp: offer.value.sdp))
        } else {
            try await createPeerConnection()
            startSignalReader()
        }
        try await waitUntilReady()
    }

    /// Server-side negotiation entry point used by the signaling listener.
    ///
    /// - Throws: ``CmxWebRTCByteTransportError`` when the peer never opens.
    func startHostNegotiation() async throws {
        guard signaling != nil else { throw CmxWebRTCByteTransportError.invalidRoute }
        guard case .idle = state else { try await connect(); return }
        state = .negotiating
        try await createPeerConnection()
        startSignalReader()
        try await waitUntilReady()
    }

    /// Receives the next binary data-channel message.
    ///
    /// - Returns: A data chunk, or nil after the peer closes.
    /// - Throws: ``CmxWebRTCByteTransportError`` or `CancellationError`.
    public func receive() async throws -> Data? {
        try Task.checkCancellation()
        switch state {
        case .ready:
            break
        case .closed:
            return nil
        case let .failed(error):
            throw error
        default:
            throw CmxWebRTCByteTransportError.notConnected
        }
        if !receiveBuffer.isEmpty {
            return receiveBuffer.removeFirst()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiveContinuation = continuation
            }
        } onCancel: {
            Task { await self.cancelReceive() }
        }
    }

    /// Sends one binary data-channel message.
    ///
    /// - Parameter data: Bytes to send. Empty writes are ignored.
    /// - Throws: ``CmxWebRTCByteTransportError`` when the channel is unavailable.
    public func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        guard case .ready = state, let dataChannel else {
            if case .closed = state { throw CmxWebRTCByteTransportError.alreadyClosed }
            throw CmxWebRTCByteTransportError.notConnected
        }
        guard dataChannel.sendData(RTCDataBuffer(data: data, isBinary: true)) else {
            throw CmxWebRTCByteTransportError.sendFailed
        }
    }

    /// Closes the data channel and signaling socket.
    public func close() async {
        if case .closed = state { return }
        await closeIfNeeded()
    }

    private func closeIfNeeded() async {
        state = .closed
        signalReaderTask?.cancel()
        signalReaderTask = nil
        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        peerDelegate = nil
        receiveContinuation?.resume(returning: nil)
        receiveContinuation = nil
        for continuation in readyContinuations.values {
            continuation.resume(throwing: CmxWebRTCByteTransportError.alreadyClosed)
        }
        readyContinuations.removeAll()
        if let signaling {
            await signaling.close()
        }
        signaling = nil
    }

    private func createPeerConnection() async throws {
        guard peerConnection == nil else { return }
        _ = RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory()
        let nativeConfiguration = RTCConfiguration()
        let iceServers: [CmxWebRTCICEServer]
        if let iceServersProvider {
            iceServers = try await iceServersProvider()
            guard !iceServers.isEmpty else {
                throw CmxWebRTCByteTransportError.iceServersUnavailable
            }
        } else {
            iceServers = configuration.iceServers
        }
        nativeConfiguration.iceServers = iceServers.map { server in
            if let username = server.username, let credential = server.credential {
                return RTCIceServer(
                    urlStrings: server.urls,
                    username: username,
                    credential: credential
                )
            }
            return RTCIceServer(urlStrings: server.urls)
        }
        nativeConfiguration.iceTransportPolicy = configuration.forceRelay ? .relay : .all
        nativeConfiguration.sdpSemantics = .unifiedPlan
        let delegate = CmxWebRTCPeerDelegate { [weak self] event in
            Task { await self?.handle(event: event) }
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let peer = factory.peerConnection(
            with: nativeConfiguration,
            constraints: constraints,
            delegate: delegate
        ) else {
            throw CmxWebRTCByteTransportError.peerConnectionUnavailable
        }
        self.factory = factory
        peerDelegate = delegate
        peerConnection = peer
    }

    private func startSignalReader() {
        guard signalReaderTask == nil else { return }
        signalReaderTask = Task { [weak self] in
            await self?.readSignals()
        }
    }

    private func readSignals() async {
        while !Task.isCancelled {
            guard let signaling else { return }
            do {
                guard let message = try await signaling.receive() else {
                    fail(with: .receiveFailed("signaling closed"))
                    return
                }
                try await handle(signal: message)
            } catch is CancellationError {
                return
            } catch {
                fail(with: .operationFailed(String(describing: error)))
                return
            }
        }
    }

    private func handle(signal: CmxWebRTCSignalMessage) async throws {
        switch signal {
        case let .offer(sdp):
            // Only the host receives an offer. A relay client has no direct
            // `clientHost`, so include the relay endpoint in this role check;
            // otherwise the client's answer is rejected as an unexpected
            // signal before the data channel can open.
            guard clientHost == nil, clientRelayURL == nil, let peerConnection else {
                throw CmxWebRTCByteTransportError.unexpectedSignal
            }
            try await setRemoteDescription(
                CmxWebRTCSessionDescriptionBox(
                    RTCSessionDescription(type: .offer, sdp: sdp)
                )
            )
            remoteDescriptionSet = true
            try await flushRemoteCandidates()
            let answer = try await createAnswer()
            try await setLocalDescription(answer)
            try await signaling?.send(.answer(sdp: answer.value.sdp))
            _ = peerConnection
        case let .answer(sdp):
            guard clientHost != nil || clientRelayURL != nil else {
                throw CmxWebRTCByteTransportError.unexpectedSignal
            }
            try await setRemoteDescription(
                CmxWebRTCSessionDescriptionBox(
                    RTCSessionDescription(type: .answer, sdp: sdp)
                )
            )
            remoteDescriptionSet = true
            try await flushRemoteCandidates()
        case let .candidate(candidate):
            if remoteDescriptionSet {
                try await addRemoteCandidate(candidate)
            } else {
                pendingRemoteCandidates.append(candidate)
            }
        case .hello, .close, .error:
            if case let .error(message) = signal {
                throw CmxWebRTCByteTransportError.operationFailed(message)
            }
        }
    }

    private func handle(event: CmxWebRTCPeerEvent) async {
        switch event {
        case let .candidate(candidate):
            try? await signaling?.send(.candidate(candidate))
        case let .dataChannel(box):
            dataChannel?.delegate = nil
            dataChannel = box.value
            box.value.delegate = peerDelegate
            if box.value.readyState == .open {
                markReady()
            }
        case let .dataChannelState(state):
            if state == RTCDataChannelState.open.rawValue {
                markReady()
            } else if state == RTCDataChannelState.closed.rawValue {
                fail(with: .receiveFailed("data channel closed"))
            }
        case let .data(data):
            guard !data.isEmpty else { return }
            if let receiveContinuation {
                self.receiveContinuation = nil
                receiveContinuation.resume(returning: data)
            } else {
                receiveBuffer.append(data)
            }
        case let .connectionState(state):
            if state == RTCPeerConnectionState.failed.rawValue {
                fail(with: .operationFailed("peer connection failed"))
            } else if state == RTCPeerConnectionState.closed.rawValue {
                fail(with: .receiveFailed("peer connection closed"))
            }
        }
    }

    private func markReady() {
        guard case .negotiating = state else { return }
        state = .ready
        for continuation in readyContinuations.values {
            continuation.resume()
        }
        readyContinuations.removeAll()
    }

    private func waitUntilReady() async throws {
        switch state {
        case .ready:
            return
        case .closed:
            throw CmxWebRTCByteTransportError.alreadyClosed
        case let .failed(error):
            throw error
        default:
            break
        }
        let operationID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readyContinuations[operationID] = continuation
                Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: self?.configuration.connectionTimeoutNanoseconds ?? 1)
                    } catch {
                        return
                    }
                    await self?.timeoutReady(operationID: operationID)
                }
            }
        } onCancel: {
            Task { await self.cancelReady(operationID: operationID) }
        }
    }

    private func timeoutReady(operationID: UUID) {
        guard let continuation = readyContinuations.removeValue(forKey: operationID) else { return }
        fail(with: .timedOut)
        continuation.resume(throwing: CmxWebRTCByteTransportError.timedOut)
    }

    private func cancelReady(operationID: UUID) {
        guard let continuation = readyContinuations.removeValue(forKey: operationID) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func cancelReceive() {
        receiveContinuation?.resume(throwing: CancellationError())
        receiveContinuation = nil
    }

    private func fail(with error: CmxWebRTCByteTransportError) {
        guard case .closed = state else {
            state = .failed(error)
            receiveContinuation?.resume(throwing: error)
            receiveContinuation = nil
            for continuation in readyContinuations.values {
                continuation.resume(throwing: error)
            }
            readyContinuations.removeAll()
            return
        }
    }

    private func createOffer() async throws -> CmxWebRTCSessionDescriptionBox {
        guard let peerConnection else { throw CmxWebRTCByteTransportError.peerConnectionUnavailable }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: CmxWebRTCByteTransportError.operationFailed(error.localizedDescription))
                } else if let sdp {
                    continuation.resume(returning: CmxWebRTCSessionDescriptionBox(sdp))
                } else {
                    continuation.resume(throwing: CmxWebRTCByteTransportError.operationFailed("missing offer"))
                }
            }
        }
    }

    private func createAnswer() async throws -> CmxWebRTCSessionDescriptionBox {
        guard let peerConnection else { throw CmxWebRTCByteTransportError.peerConnectionUnavailable }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.answer(for: constraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: CmxWebRTCByteTransportError.operationFailed(error.localizedDescription))
                } else if let sdp {
                    continuation.resume(returning: CmxWebRTCSessionDescriptionBox(sdp))
                } else {
                    continuation.resume(throwing: CmxWebRTCByteTransportError.operationFailed("missing answer"))
                }
            }
        }
    }

    private func setLocalDescription(_ description: CmxWebRTCSessionDescriptionBox) async throws {
        guard let peerConnection else { throw CmxWebRTCByteTransportError.peerConnectionUnavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            peerConnection.setLocalDescription(description.value) { error in
                if let error {
                    continuation.resume(throwing: CmxWebRTCByteTransportError.operationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func setRemoteDescription(_ description: CmxWebRTCSessionDescriptionBox) async throws {
        guard let peerConnection else { throw CmxWebRTCByteTransportError.peerConnectionUnavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            peerConnection.setRemoteDescription(description.value) { error in
                if let error {
                    continuation.resume(throwing: CmxWebRTCByteTransportError.operationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func addRemoteCandidate(_ candidate: CmxWebRTCCandidate) async throws {
        guard let peerConnection else { throw CmxWebRTCByteTransportError.peerConnectionUnavailable }
        let nativeCandidate = RTCIceCandidate(
            sdp: candidate.sdp,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            peerConnection.add(nativeCandidate) { error in
                if let error {
                    continuation.resume(throwing: CmxWebRTCByteTransportError.operationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func flushRemoteCandidates() async throws {
        let candidates = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        for candidate in candidates {
            try await addRemoteCandidate(candidate)
        }
    }
}
