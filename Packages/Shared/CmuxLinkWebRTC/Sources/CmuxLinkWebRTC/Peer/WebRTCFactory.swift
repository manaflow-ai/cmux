@preconcurrency import WebRTC

/// The process-wide libwebrtc factory per network mode. libwebrtc factories
/// own threads; one per mode is shared by every peer connection. In loopback
/// mode (both ends in one test or bench process) the accepting side gets its
/// own factory, so each end has its own network thread as two devices do: with
/// one shared thread, the sender's SCTP bursts starve the receiving socket and
/// the drops collapse throughput (d2-bakeoff.md).
final class WebRTCFactory: @unchecked Sendable {
    // lint:allow singleton: libwebrtc factories own their threads; one per mode per process.
    private static let standard = WebRTCFactory(loopback: false)
    private static let loopback = WebRTCFactory(loopback: true)
    private static let loopbackHost = WebRTCFactory(loopback: true)

    let factory: RTCPeerConnectionFactory

    private init(loopback: Bool) {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        let options = RTCPeerConnectionFactoryOptions()
        options.ignoreLoopbackNetworkAdapter = !loopback
        factory.setOptions(options)
    }

    /// `host` is true for the accepting side (acceptor, datagram listener).
    static func shared(for mode: WebRTCNetworkMode, host: Bool = false) -> WebRTCFactory {
        mode == .loopbackOnly ? (host ? loopbackHost : loopback) : standard
    }

    /// The configuration every cmux peer connection uses (section 5).
    func configuration(ice: ICEConfiguration) -> RTCConfiguration {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.keyType = .ECDSA
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceTransportPolicy = .all
        configuration.tcpCandidatePolicy = .enabled
        configuration.enableImplicitRollback = true
        configuration.iceServers = Self.servers(ice)
        return configuration
    }

    static func servers(_ ice: ICEConfiguration) -> [RTCIceServer] {
        ice.servers.map { server in
            RTCIceServer(urlStrings: server.urls, username: server.username, credential: server.credential)
        }
    }

    func constraints() -> RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }
}
