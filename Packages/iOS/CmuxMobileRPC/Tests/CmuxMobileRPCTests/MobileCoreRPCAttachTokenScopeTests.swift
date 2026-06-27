import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCAttachTokenScopeTests {
    private static let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func ticketCoveredTerminalMouseDoesNotWaitForStackToken() async throws {
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
            method: "mobile.terminal.mouse",
            params: [
                "workspace_id": "workspace-main",
                "surface_id": "terminal-main",
                "client_id": "ios-client",
                "col": 4,
                "row": 8,
            ]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "mobile.terminal.mouse")
        #expect(frame.workspaceID == "workspace-main")
        #expect(frame.terminalID == "terminal-main")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == nil)
        #expect(frame.hasAuth)
        #expect(await tokenStarted.isSet() == false)
    }

    @Test func macWideWorkspaceGroupMutationDoesNotWaitForStackToken() async throws {
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
            method: "workspace.group.collapse",
            params: ["group_id": "group-main"]
        )
        let frame = try await sentFrame(client: client, transport: transport, request: request)

        #expect(frame.method == "workspace.group.collapse")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == nil)
        #expect(frame.hasAuth)
        #expect(await tokenStarted.isSet() == false)
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
