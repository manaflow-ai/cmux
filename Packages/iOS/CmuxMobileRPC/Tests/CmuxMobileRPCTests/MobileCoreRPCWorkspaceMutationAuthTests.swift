import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCWorkspaceMutationAuthTests {
    @Test func terminalScopedWorkspaceActionsUseStackToken() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "fresh-stack-token",
            now: { now }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: now.addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "workspace.action",
            params: [
                "workspace_id": "workspace-main",
                "action": "mark_read",
            ]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "workspace.action")
        #expect(frame.workspaceID == "workspace-main")
        #expect(frame.attachToken == nil)
        #expect(frame.stackAccessToken == "fresh-stack-token")
        #expect(frame.hasAuth)
    }

    private func sentFrame(
        client: MobileCoreRPCClient,
        transport: QueuedCancellationProbeTransport,
        request: Data
    ) async throws -> RecordedRPCRequest {
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value
        return try #require(sent.first)
    }
}
