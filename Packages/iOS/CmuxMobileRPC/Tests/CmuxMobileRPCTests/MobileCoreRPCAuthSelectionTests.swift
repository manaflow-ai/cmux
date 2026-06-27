import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCAuthSelectionTests {
    private static let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)

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
            },
            now: { Self.fixedNow }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
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

    @Test func attachTokenIsNotSentOverUntrustedRoute() async throws {
        let tokenStarted = AsyncFlag()
        let route = try hostPortRoute(kind: .tailscale, host: "192.168.1.20", port: 58465)
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
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
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
        let request = try MobileCoreRPCClient.requestData(
            method: "workspace.list",
            params: ["workspace_id": "workspace-main"]
        )

        do {
            _ = try await client.sendRequest(request)
            Issue.record("Expected untrusted route to reject bearer credentials")
        } catch MobileShellConnectionError.insecureManualRoute {
        } catch {
            Issue.record("Expected insecureManualRoute, got \(error)")
        }

        #expect(try await transport.sentRequests().isEmpty)
        #expect(await tokenStarted.isSet() == false)
    }

    @Test func unscopedWorkspaceListUsesStackTokenForScopedAttachTicket() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "fresh-stack-token",
            now: { Self.fixedNow }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
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
        let request = try MobileCoreRPCClient.requestData(method: "workspace.list")
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "workspace.list")
        #expect(frame.attachToken == nil)
        #expect(frame.stackAccessToken == "fresh-stack-token")
        #expect(frame.hasAuth)
    }

    @Test func sameAccountScopedWorkspaceListUsesAttachToken() async throws {
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
            workspaceID: "workspace-main",
            terminalID: nil,
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
        let request = try MobileCoreRPCClient.requestData(method: "workspace.list")
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "workspace.list")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == nil)
        #expect(frame.hasAuth)
        #expect(await tokenStarted.isSet() == false)
    }

    @Test func scopedWorkspaceCreateUsesStackToken() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "fresh-stack-token",
            now: { Self.fixedNow }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
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
        let request = try MobileCoreRPCClient.requestData(
            method: "workspace.create",
            params: ["title": "New workspace"]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "workspace.create")
        #expect(frame.attachToken == nil)
        #expect(frame.stackAccessToken == "fresh-stack-token")
        #expect(frame.hasAuth)
    }

    @Test func sameAccountScopedWorkspaceCreateUsesAttachToken() async throws {
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
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
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
        let request = try MobileCoreRPCClient.requestData(
            method: "workspace.create",
            params: ["title": "New workspace"]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "workspace.create")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == nil)
        #expect(frame.hasAuth)
        #expect(await tokenStarted.isSet() == false)
    }

    @Test func terminalScopedTerminalCreateUsesStackToken() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "fresh-stack-token",
            now: { Self.fixedNow }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
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
        let request = try MobileCoreRPCClient.requestData(
            method: "terminal.create",
            params: ["workspace_id": "workspace-main"]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "terminal.create")
        #expect(frame.workspaceID == "workspace-main")
        #expect(frame.attachToken == nil)
        #expect(frame.stackAccessToken == "fresh-stack-token")
        #expect(frame.hasAuth)
    }

    @Test func terminalScopedWorkspaceListWithoutWorkspaceUsesStackToken() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "fresh-stack-token",
            now: { Self.fixedNow }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
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
        let request = try MobileCoreRPCClient.requestData(
            method: "workspace.list",
            params: ["terminal_id": "terminal-main"]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "workspace.list")
        #expect(frame.workspaceID == nil)
        #expect(frame.terminalID == "terminal-main")
        #expect(frame.attachToken == nil)
        #expect(frame.stackAccessToken == "fresh-stack-token")
        #expect(frame.hasAuth)
    }

    @Test func workspaceScopedTerminalCreateUsesAttachTokenInScope() async throws {
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
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
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
        let request = try MobileCoreRPCClient.requestData(
            method: "terminal.create",
            params: ["workspace_id": "workspace-main"]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "terminal.create")
        #expect(frame.workspaceID == "workspace-main")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == nil)
        #expect(frame.hasAuth)
        #expect(await tokenStarted.isSet() == false)
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
            },
            now: { Self.fixedNow }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
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

    @Test(arguments: ["mobile.events.subscribe", "mobile.events.unsubscribe"])
    func macWideEventSubscriptionDoesNotWaitForStackToken(method: String) async throws {
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
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
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
        let request = try MobileCoreRPCClient.requestData(
            method: method,
            params: method == "mobile.events.subscribe"
                ? ["stream_id": "events", "topics": ["workspace.updated"]]
                : ["stream_id": "events"]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == method)
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == nil)
        #expect(frame.hasAuth)
        #expect(await tokenStarted.isSet() == false)
    }

    @Test(arguments: ["mobile.events.subscribe", "mobile.events.unsubscribe"])
    func scopedEventSubscriptionUsesStackToken(method: String) async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "fresh-stack-token",
            now: { Self.fixedNow }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
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
        let request = try MobileCoreRPCClient.requestData(
            method: method,
            params: method == "mobile.events.subscribe"
                ? ["stream_id": "events", "topics": ["workspace.updated"]]
                : ["stream_id": "events"]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == method)
        #expect(frame.attachToken == nil)
        #expect(frame.stackAccessToken == "fresh-stack-token")
        #expect(frame.hasAuth)
    }

    @Test func expiredTicketCoveredWorkspaceListFallsBackToStackTokenOnTrustedRoute() async throws {
        let now = Self.fixedNow
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
            stackAccessToken: nil,
            now: { Self.fixedNow }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
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
