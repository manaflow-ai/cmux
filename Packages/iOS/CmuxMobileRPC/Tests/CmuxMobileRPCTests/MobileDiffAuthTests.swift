import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileDiffAuthTests {
    @Test func attachTicketCoverageMatchesRequestedWorkspace() async throws {
        let covered = try await sentRequest(
            requestedWorkspaceID: "workspace-main",
            ticketWorkspaceID: "workspace-main"
        )
        #expect(covered.attachToken == "ticket-secret")
        #expect(covered.stackAccessToken == "test-stack-token")

        let outsideScope = try await sentRequest(
            requestedWorkspaceID: "workspace-other",
            ticketWorkspaceID: "workspace-main"
        )
        #expect(outsideScope.attachToken == nil)
        #expect(outsideScope.stackAccessToken == "test-stack-token")
    }

    private func sentRequest(
        requestedWorkspaceID: String,
        ticketWorkspaceID: String
    ) async throws -> RecordedRPCRequest {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "test-stack-token"
        )
        let ticket = try CmxAttachTicket(
            workspaceID: ticketWorkspaceID,
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.diff.load",
            params: ["workspace_id": requestedWorkspaceID]
        )
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value
        return try #require(sent.first)
    }
}
