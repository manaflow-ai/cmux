import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCSameAccountAttachTokenHotPathTests {
    private static let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func scopedWorkspaceListUsesAttachToken() async throws {
        let frame = try await sentFrame(
            ticketWorkspaceID: "workspace-main",
            ticketTerminalID: nil,
            request: MobileCoreRPCClient.requestData(
                method: "workspace.list",
                params: ["workspace_id": "workspace-main"]
            )
        )

        #expect(frame.method == "workspace.list")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == nil)
        #expect(frame.hasAuth)
    }

    @Test func macWideWorkspaceCreateUsesAttachToken() async throws {
        let frame = try await sentFrame(
            ticketWorkspaceID: "",
            ticketTerminalID: nil,
            request: MobileCoreRPCClient.requestData(
                method: "workspace.create",
                params: ["title": "New workspace"]
            )
        )

        #expect(frame.method == "workspace.create")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == nil)
        #expect(frame.hasAuth)
    }

    private func sentFrame(
        ticketWorkspaceID: String,
        ticketTerminalID: String?,
        request: Data
    ) async throws -> RecordedRPCRequest {
        let tokenStarted = AsyncFlag()
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessTokenProvider: {
                await tokenStarted.set()
                return "fresh-stack-token"
            },
            now: { Self.fixedNow }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: ticketWorkspaceID,
            terminalID: ticketTerminalID,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macUserEmail: "user@example.com",
            macUserID: "user-1",
            routes: [route],
            expiresAt: Self.fixedNow.addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value
        #expect(await tokenStarted.isSet() == false)
        return try #require(sent.first)
    }
}
