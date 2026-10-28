import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCTransportPreparationTests {
    @Test func transportPreparationPreservesTheEstablishmentError() async throws {
        let failure = CmxRouteTransportFactoryError.unsupportedRouteKind(.iroh)
        let transport = ControllableResponseTransport(closeEndsReceive: true, connectFailure: failure)
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59123)
        let runtime = TestMobileSyncRuntime(transportFactory: FixedTransportFactory(transport: transport))
        let client = MobileCoreRPCClient(runtime: runtime, route: route,
            ticket: try CmxAttachTicket(workspaceID: "main", terminalID: nil, macDeviceID: "test-mac",
                macDisplayName: "Test Mac", routes: [route]), allowsStackAuthFallback: true)
        await #expect(throws: failure) { try await client.connectTransport() }
        #expect(await transport.connectCount == 1)
        #expect(await transport.sentIDs().isEmpty)
        await client.disconnectAndWaitForTransportDrain()
    }

    @Test func transportPreparationSendsNoRPCAndReusesTheAdmittedConnection() async throws {
        let transport = ControllableResponseTransport(closeEndsReceive: true,
            automaticallyRespondingRequestIDs: ["probe"])
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59123)
        let runtime = TestMobileSyncRuntime(transportFactory: FixedTransportFactory(transport: transport))
        let client = MobileCoreRPCClient(runtime: runtime, route: route,
            ticket: try CmxAttachTicket(workspaceID: "main", terminalID: nil, macDeviceID: "test-mac",
                macDisplayName: "Test Mac", routes: [route]), allowsStackAuthFallback: true)
        try await client.connectTransport()
        try await client.connectTransport()
        #expect(await transport.connectCount == 1)
        #expect(await transport.sentIDs().isEmpty)
        _ = try await client.sendRequest(MobileCoreRPCClient.requestData(method: "mobile.host.status", id: "probe"))
        #expect(await transport.connectCount == 1)
        #expect(await transport.sentIDs() == ["probe"])
        await client.disconnectAndWaitForTransportDrain()
        #expect(await transport.closed())
    }
}
