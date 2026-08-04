import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileSurfaceInventoryTests {
    @Test func absentInventoryDecodesAsNil() throws {
        let response = try MobileSyncWorkspaceListResponse.decode(Data(#"{"workspaces":[{"id":"w","title":"W","is_selected":true,"terminals":[]}]}"#.utf8))
        #expect(response.workspaces.first?.surfaces == nil)
        #expect(MobileWorkspacePreview(remote: response.workspaces[0]).surfaces.isEmpty)
    }

    @Test func unknownKindSurvivesProjection() throws {
        let response = try MobileSyncWorkspaceListResponse.decode(Data(#"{"workspaces":[{"id":"w","title":"W","is_selected":true,"terminals":[],"surfaces":[{"surface_id":"s","kind":"future.canvas","title":"Canvas","file_path":"/tmp/a"}]}]}"#.utf8))
        let surface = try #require(MobileWorkspacePreview(remote: response.workspaces[0]).surfaces.first)
        #expect(surface.kind == .other("future.canvas"))
        #expect(surface.filePath == "/tmp/a")
    }

    @Test(arguments: [
        "mobile.panel.artifact.stat",
        "mobile.panel.artifact.fetch",
        "mobile.panel.artifact.thumbnail",
    ])
    func panelArtifactRequestsRetainWorkspaceTicketAuthorization(method: String) async throws {
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
        let request = try MobileCoreRPCClient.requestData(
            method: method,
            params: [
                "workspace_id": "other-workspace",
                "surface_id": "surface",
                "path": "/tmp/a",
            ]
        )

        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value

        let frame = try #require(sent.first)
        #expect(frame.method == method)
        #expect(frame.workspaceID == "other-workspace")
        #expect(frame.attachToken == nil)
        #expect(frame.stackAccessToken == "test-stack-token")
        #expect(frame.hasAuth)
    }
}
