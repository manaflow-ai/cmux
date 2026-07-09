import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCWorkspaceMutationAuthTests {
    @Test func workspaceMoveCarriesWorkspaceScopedAttachTicketContext() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
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
            method: "workspace.move",
            params: [
                "workspace_id": "workspace-main",
                "before_workspace_id": "workspace-next",
            ]
        )
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value

        let frame = try #require(sent.first)
        #expect(frame.method == "workspace.move")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == "test-stack-token")
        #expect(frame.hasAuth)
    }

    @Test func workspaceGroupActionCarriesWorkspaceScopedAttachTicketContext() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
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
            method: "workspace.group.action",
            params: [
                "group_id": "group-main",
                "action": "rename",
                "title": "Project Alpha",
            ]
        )
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value

        let frame = try #require(sent.first)
        #expect(frame.method == "workspace.group.action")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == "test-stack-token")
        #expect(frame.hasAuth)
    }

    @Test func workspaceGroupActionCarriesMacWideAttachTicketContext() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
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
            method: "workspace.group.action",
            params: [
                "group_id": "group-main",
                "action": "rename",
                "title": "Project Alpha",
            ]
        )
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value

        let frame = try #require(sent.first)
        #expect(frame.method == "workspace.group.action")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == "test-stack-token")
        #expect(frame.hasAuth)
    }

    @Test func workspaceGroupCreateCarriesWorkspaceScopedAttachTicketContext() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
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
            method: "workspace.group.create",
            params: [
                "title": "Ops",
            ]
        )
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value

        let frame = try #require(sent.first)
        #expect(frame.method == "workspace.group.create")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == "test-stack-token")
        #expect(frame.hasAuth)
    }
}
