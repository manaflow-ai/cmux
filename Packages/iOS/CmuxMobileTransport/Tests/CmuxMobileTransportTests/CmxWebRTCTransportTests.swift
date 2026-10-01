import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileTransport

private actor WebRTCExchangeProbe {
    private(set) var received: Data?
    private(set) var errorDescription: String?

    func receiveAndReply(on transport: CmxWebRTCByteTransport) async {
        do {
            received = try await transport.receive()
            try await transport.send(Data("host-reply".utf8))
        } catch {
            errorDescription = String(describing: error)
        }
    }
}

@Test func webRTCConfigurationParsesCloudflareCredentialShape() throws {
    let defaults = UserDefaults(suiteName: "cmux.webrtc.tests.\(UUID().uuidString)")!
    let json = #"{"iceServers":[{"urls":["turn:turn.example:443"],"username":"user","credential":"credential"}]}"#
    let configuration = CmxWebRTCConfiguration(
        environment: ["CMUX_WEBRTC_ICE_SERVERS_JSON": json, "CMUX_WEBRTC_FORCE_RELAY": "1"],
        userDefaults: defaults
    )

    #expect(configuration.forceRelay)
    #expect(configuration.iceServers == [
        CmxWebRTCICEServer(
            urls: ["turn:turn.example:443"],
            username: "user",
            credential: "credential"
        )
    ])
}

@Test func webRTCSignalMessageRoundTripsWithoutChangingToken() throws {
    let message = CmxWebRTCSignalMessage.candidate(CmxWebRTCCandidate(
        sdp: "candidate:1 1 UDP 1 127.0.0.1 1234 typ host",
        sdpMLineIndex: 0,
        sdpMid: "0"
    ))
    let data = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(CmxWebRTCSignalMessage.self, from: data)

    #expect(decoded == message)
    #expect(!String(decoding: data, as: UTF8.self).contains("token"))
}

@Test func webRTCFactoryBuildsOnlyTokenBoundWebRTCRoutes() async throws {
    let factory = CmxWebRTCByteTransportFactory()
    let validRoute = try CmxAttachRoute(
        id: "webrtc",
        kind: .webrtc,
        endpoint: .url("webrtc://127.0.0.1:58465?token=test-token")
    )
    let transport = try factory.makeTransport(for: CmxByteTransportRequest(
        route: validRoute,
        expectedPeerDeviceID: "device",
        authorizationMode: .stackBearer
    ))
    await transport.close()

    let missingToken = try CmxAttachRoute(
        id: "webrtc",
        kind: .webrtc,
        endpoint: .url("webrtc://127.0.0.1:58465")
    )
    #expect(throws: CmxWebRTCByteTransportError.invalidRoute) {
        _ = try factory.makeTransport(for: missingToken)
    }
}

@Test(.timeLimit(.minutes(1)))
func webRTCByteTransportExchangesDataOverLoopback() async throws {
    let probe = WebRTCExchangeProbe()
    let server = CmxWebRTCSignalingServer(
        preferredPort: 0,
        configuration: CmxWebRTCConfiguration()
    ) { transport in
        await probe.receiveAndReply(on: transport)
    }
    try await server.start()
    guard let endpoint = await server.endpoint(),
          let routeURL = await server.routeURL(host: "127.0.0.1") else {
        Issue.record("WebRTC signaling server did not publish an endpoint")
        return
    }
    let route = try CmxAttachRoute(
        id: "webrtc",
        kind: .webrtc,
        endpoint: .url(routeURL),
        priority: -20_000
    )
    let factory = CmxWebRTCByteTransportFactory()
    let client = try factory.makeTransport(for: CmxByteTransportRequest(
        route: route,
        expectedPeerDeviceID: "device",
        authorizationMode: .stackBearer
    ))
    try await client.connect()
    try await client.send(Data("client-payload".utf8))
    let reply = try await client.receive()

    #expect(reply == Data("host-reply".utf8))
    #expect(await probe.received == Data("client-payload".utf8))
    #expect(await probe.errorDescription == nil)
    #expect(endpoint.port > 0)

    await client.close()
    await server.stop()
}

@Test func webRTCExperimentRequiresExplicitEnvironmentOptIn() {
    #expect(CmxWebRTCExperiment.isEnabled(environment: [:]) == false)
    #expect(CmxWebRTCExperiment.isEnabled(environment: [
        CmxWebRTCExperiment.environmentKey: "1"
    ]))
    #expect(CmxWebRTCExperiment.isEnabled(environment: [
        CmxWebRTCExperiment.environmentKey: "true"
    ]) == false)
}
