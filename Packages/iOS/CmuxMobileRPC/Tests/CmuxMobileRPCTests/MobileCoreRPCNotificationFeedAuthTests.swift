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
        "workstream.feed.list",
        "workstream.feed.action",
        "workstream.feed.reply",
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
        let params: [String: Any]
        if ["notification.feed.mark_read", "notification.feed.mark_unread"].contains(method) {
            params = ["notification_ids": ["notification"]]
        } else if method == "workstream.feed.list" {
            params = ["cursor": "00000000-0000-0000-0000-000000000300"]
        } else {
            params = [:]
        }
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
        if method == "workstream.feed.list" {
            #expect(frame.cursor == "00000000-0000-0000-0000-000000000300")
        }
    }
}
