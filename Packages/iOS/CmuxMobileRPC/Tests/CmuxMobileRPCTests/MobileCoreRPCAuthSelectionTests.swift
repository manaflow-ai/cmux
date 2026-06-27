import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCAuthSelectionTests {
    @Test func scopedWorkspaceListDoesNotWaitForStackToken() async throws {
        let tokenStarted = AsyncFlag()
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessTokenProvider: {
                await tokenStarted.set()
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                return "late-stack-token"
            }
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
            method: "workspace.list",
            params: ["workspace_id": "workspace-main"]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "workspace.list")
        #expect(frame.workspaceID == "workspace-main")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == nil)
        #expect(frame.hasAuth)
        #expect(await tokenStarted.isSet() == false)
    }

    @Test func unscopedWorkspaceListUsesStackTokenForScopedAttachTicket() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "fresh-stack-token"
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
        let request = try MobileCoreRPCClient.requestData(method: "workspace.list")
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "workspace.list")
        #expect(frame.attachToken == nil)
        #expect(frame.stackAccessToken == "fresh-stack-token")
        #expect(frame.hasAuth)
    }

    @Test func ticketCoveredTerminalScrollDoesNotWaitForStackToken() async throws {
        let tokenStarted = AsyncFlag()
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessTokenProvider: {
                await tokenStarted.set()
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                return "late-stack-token"
            }
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
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.terminal.scroll",
            params: [
                "workspace_id": "workspace-main",
                "surface_id": "terminal-main",
                "delta_lines": 3,
                "col": 0,
                "row": 0,
            ]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "mobile.terminal.scroll")
        #expect(frame.workspaceID == "workspace-main")
        #expect(frame.terminalID == "terminal-main")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == nil)
        #expect(frame.hasAuth)
        #expect(await tokenStarted.isSet() == false)
    }

    @Test func eventSubscriptionUsesStackTokenEvenWithAttachToken() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "fresh-stack-token"
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
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.events.subscribe",
            params: [
                "stream_id": "events",
                "topics": ["workspace.updated"],
            ]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "mobile.events.subscribe")
        #expect(frame.attachToken == nil)
        #expect(frame.stackAccessToken == "fresh-stack-token")
        #expect(frame.hasAuth)
    }

    @Test func expiredTicketCoveredWorkspaceListFallsBackToStackTokenOnTrustedRoute() async throws {
        let now = Date()
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "fresh-stack-token",
            now: { now }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: now.addingTimeInterval(-60),
            authToken: "expired-ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let request = try MobileCoreRPCClient.requestData(method: "workspace.list")
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "workspace.list")
        #expect(frame.attachToken == nil)
        #expect(frame.stackAccessToken == "fresh-stack-token")
        #expect(frame.hasAuth)
    }

    @Test func workspaceActionsUseMacWideAttachTicketAuth() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: nil
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
            method: "workspace.action",
            params: [
                "workspace_id": "workspace-main",
                "action": "mark_read",
            ]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "workspace.action")
        #expect(frame.workspaceID == "workspace-main")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == nil)
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
