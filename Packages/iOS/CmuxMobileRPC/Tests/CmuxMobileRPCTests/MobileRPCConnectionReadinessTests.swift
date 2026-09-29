import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@MainActor
@Suite struct MobileRPCConnectionReadinessTests {
    @Test(.timeLimit(.minutes(1)))
    func readinessDefersNewDialsAndPreservesAnAdmittedConnection() async throws {
        let readiness = RPCConnectionReadiness(permitsConnection: false)
        let transport = ReleasableConnectTransport()
        await transport.releaseConnect()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59147)
        let runtime = TestMobileSyncRuntime(connectionReadiness: readiness,
            transportFactory: FixedTransportFactory(transport: transport))
        let ticket = try CmxAttachTicket(workspaceID: "workspace", terminalID: "terminal",
            macDeviceID: "readiness-mac", macDisplayName: "Mac", routes: [route],
            expiresAt: Date().addingTimeInterval(60), authToken: "ticket-secret")
        let client = MobileCoreRPCClient(runtime: runtime, route: route, ticket: ticket,
            allowsStackAuthFallback: true)
        let blocked = try MobileCoreRPCClient.requestData(method: "mobile.host.status", id: "blocked")
        do {
            _ = try await client.sendRequest(blocked)
            Issue.record("Unavailable lifecycle readiness must defer a new dial")
        } catch is CancellationError {} catch {
            Issue.record("Readiness deferral must be cancellation, got \(error)")
        }
        #expect(await transport.connectCount == 0)

        readiness.permitsConnection = true
        let ready = try MobileCoreRPCClient.requestData(method: "mobile.host.status", id: "ready")
        #expect(!(try await client.sendRequest(ready)).isEmpty)
        #expect(await transport.connectCount == 1)

        readiness.permitsConnection = false
        let admitted = try MobileCoreRPCClient.requestData(method: "mobile.host.status", id: "admitted")
        #expect(!(try await client.sendRequest(admitted)).isEmpty)
        #expect(await transport.connectCount == 1)
        await client.disconnect()
    }
}
