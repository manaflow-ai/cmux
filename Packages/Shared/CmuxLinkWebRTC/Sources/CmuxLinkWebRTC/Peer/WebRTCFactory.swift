@preconcurrency import WebRTC

/// The process-wide libwebrtc factory per network mode. libwebrtc factories
/// own threads; one per mode is shared by every peer connection.
final class WebRTCFactory: @unchecked Sendable {
    // lint:allow singleton: libwebrtc factories own their threads; one per mode per process.
    private static let standard = WebRTCFactory(loopback: false)
    private static let loopback = WebRTCFactory(loopback: true)

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

    static func shared(for mode: WebRTCNetworkMode) -> WebRTCFactory {
        mode == .loopbackOnly ? loopback : standard
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
