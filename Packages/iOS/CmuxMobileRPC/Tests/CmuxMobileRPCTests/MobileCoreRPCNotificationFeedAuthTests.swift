import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCNotificationFeedAuthTests {
    @Test(arguments: [
        "notification.feed.list",
        "notification.feed.mark_read",
        "notification.feed.mark_unread",
        "notification.feed.mark_all_read",
    ])
    func feedRequestsUseAccountAuthorizationWithoutWorkspaceTicketScope(method: String) async throws {
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 58_465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "test-stack-token"
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
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
        let params: [String: Any] = ["notification.feed.mark_read", "notification.feed.mark_unread"].contains(method)
            ? ["notification_ids": ["notification"]]
            : [:]
        let request = try MobileCoreRPCClient.requestData(method: method, params: params)

        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value

        let frame = try #require(sent.first)
        #expect(frame.method == method)
        #expect(frame.attachToken == nil)
        #expect(frame.stackAccessToken == "test-stack-token")
        #expect(frame.hasAuth)
    }
}
