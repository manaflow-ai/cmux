import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohByteTransportTests {
    @Test
    func factoryConnectsIrohRouteThroughInjectedSupervisorAndContext() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ab", count: 32)
        )
        let remoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "cd", count: 32)
        )
        let admissionCodec = CmxIrohAdmissionAckCodec()
        let controlReceive = TestIrohReceiveStream(
            buffer: admissionCodec.encode(.accepted)
                + admissionCodec.encodeFrame(.serverReady)
                + Data("response".utf8)
        )
        let controlSend = TestIrohSendStream()
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [
                CmxIrohBidirectionalStream(
                    receiveStream: controlReceive,
                    sendStream: controlSend
                ),
            ]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let endpointFactory = TestIrohEndpointFactory(endpoints: [endpoint])
        let supervisor = CmxIrohEndpointSupervisor(
            factory: endpointFactory,
            configuration: try endpointConfiguration()
        )
        _ = try await supervisor.activate()
        let credential = try CmxIrohAdmissionCredential.pairGrant("e30.e30.AA")
        let contextProvider = TestIrohClientContextProvider(
            context: CmxIrohClientContext(
                dialPlan: try testIrohDialPlan(),
                credential: credential
            )
        )
        let route = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(identity: remoteIdentity, pathHints: []),
            priority: 0
        )
        let factory = CmxIrohByteTransportFactory(
            supervisor: supervisor,
            contextProvider: contextProvider
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "123e4567-e89b-42d3-a456-426614174004",
            authorizationMode: .transportAdmission
        )
        let transport = try factory.makeTransport(for: request)

        try await transport.connect()
        try await transport.send(Data("request".utf8))

        #expect(try await transport.receive() == Data("response".utf8))
        #expect(await contextProvider.requests() == [request])
        let sent = await controlSend.observedSentBuffers()
        #expect(sent.count == 3)
        #expect(sent[1] == admissionCodec.encodeFrame(.clientReady))
        #expect(sent[2] == Data("request".utf8))
    }

    @Test
    func factoryRejectsLegacyHostPortRoutes() throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ab", count: 32)
        )
        let endpoint = TestIrohEndpoint(identity: localIdentity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try endpointConfiguration()
        )
        let provider = TestIrohClientContextProvider(
            context: CmxIrohClientContext(
                dialPlan: try testIrohDialPlan(),
                credential: try .pairGrant("e30.e30.AA")
            )
        )
        let factory = CmxIrohByteTransportFactory(
            supervisor: supervisor,
            contextProvider: provider
        )
        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 42),
            priority: 0
        )

        #expect(throws: CmxIrohByteTransportError.unsupportedRouteKind(.tailscale)) {
            try factory.makeTransport(for: tailscale)
        }
    }

    private func endpointConfiguration() throws -> CmxIrohEndpointConfiguration {
        try CmxIrohEndpointConfiguration(
            secretKey: CmxIrohSecretKey(bytes: Data(repeating: 1, count: 32)),
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            managedRelayURLs: [],
            relays: []
        )
    }
}
