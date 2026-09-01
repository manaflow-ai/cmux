import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCChatArtifactAuthTests {
    @Test(arguments: [
        "mobile.chat.artifact.stat",
        "mobile.chat.artifact.fetch",
        "mobile.chat.artifact.thumbnail",
        "mobile.chat.artifact.list",
        "mobile.chat.artifact.save",
        "mobile.chat.artifact.gallery",
    ])
    func chatArtifactRequestsRetainSessionAuthorizationContext(method: String) async throws {
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 58_465
        )

        for workspaceID in ["workspace-main", ""] {
            let transport = QueuedCancellationProbeTransport()
            let runtime = TestMobileSyncRuntime(
                transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
                stackAccessToken: "test-stack-token"
            )
            let ticket = try CmxAttachTicket(
                workspaceID: workspaceID,
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
            var params: [String: Any] = ["session_id": "session"]
            if method != "mobile.chat.artifact.gallery" {
                params["path"] = "/tmp/artifact"
            }
            let request = try MobileCoreRPCClient.requestData(
                method: method,
                params: params
            )
            let task = Task { try await client.sendRequest(request) }
            let sent = try await transport.waitForSentRequestCount(1)
            task.cancel()
            await transport.releaseFirstSend()
            _ = try? await task.value

            let frame = try #require(sent.first)
            #expect(frame.method == method)
            #expect(frame.attachToken == "ticket-secret")
            #expect(frame.stackAccessToken == "test-stack-token")
            #expect(frame.hasAuth)
            await client.disconnect()
        }
    }
}
