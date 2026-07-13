import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCStalledWriteRecoveryTests {
    @Test func timedOutInFlightWriteRecyclesTransportForNextRequest() async throws {
        let stalled = StalledWriteTransport()
        let recovery = ResponseTimeoutSurvivalTransport()
        let factory = StalledWriteRecoveryTransportFactory(
            stalled: stalled,
            recovery: recovery
        )
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 59135
        )
        let runtime = TestMobileSyncRuntime(
            transportFactory: factory,
            rpcRequestTimeoutNanoseconds: 50_000_000
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )

        let stalledRequest = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "a",
            ],
            id: "stalled-write"
        )
        do {
            _ = try await client.sendRequest(stalledRequest)
            Issue.record("Expected the stalled write to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }

        let retryRequest = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "b",
            ],
            id: "second-after-timeout"
        )
        do {
            let data = try await client.sendRequest(
                retryRequest,
                timeoutNanoseconds: 500_000_000
            )
            let response = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: String]
            )
            #expect(response["status"] == "ok")
        } catch {
            Issue.record("The request after a stalled write should reconnect, got \(error)")
        }

        #expect(factory.createdTransportCount() == 2)
        #expect(await stalled.closed())
        await client.disconnect()
    }
}
