import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCWorkspaceMoveTests {
    @Test func workspaceMoveCarriesMacWideAttachTicketContext() async throws {
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "test-stack-token"
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
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
        let request = try MobileCoreRPCClient.requestData(
            method: "workspace.move",
            params: [
                "workspace_id": "workspace-main",
                "group_id": "group-main",
                "before_workspace_id": "workspace-next",
            ]
        )
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value

        let frame = try #require(sent.first)
        #expect(frame.method == "workspace.move")
        #expect(frame.workspaceID == "workspace-main")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == "test-stack-token")
        #expect(frame.hasAuth)
    }
}
