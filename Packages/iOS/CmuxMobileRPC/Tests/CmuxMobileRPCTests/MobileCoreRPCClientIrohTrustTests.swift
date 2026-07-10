import CMUXMobileCore
import CmuxMobileRPC
import Testing

@Suite struct MobileCoreRPCClientIrohTrustTests {
    @Test func irohEndpointMismatchWithholdsStackTokenForAuthorizedRequest() async throws {
        let route = try peerRoute(endpointID: "changed-endpoint")
        let transport = QueuedCancellationProbeTransport()
        let tokenProviderCalled = AsyncFlag()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessTokenProvider: {
                await tokenProviderCalled.set()
                return "must-not-send"
            },
            irohEndpointTrustValidator: { _, _ in
                throw MobileShellConnectionError.irohEndpointChanged("endpoint changed")
            }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-1",
            macDisplayName: "Mac",
            routes: [route]
        )
        let client = MobileCoreRPCClient(runtime: runtime, route: route, ticket: ticket, allowsStackAuthFallback: true)

        await #expect(throws: MobileShellConnectionError.self) {
            _ = try await client.sendRequest(try MobileCoreRPCClient.requestData(method: "workspace.create"))
        }

        #expect(await tokenProviderCalled.isSet() == false)
        #expect(try await transport.sentRequests().isEmpty)
    }

    @Test func irohEndpointMismatchKeepsHostStatusProbeTokenless() async throws {
        let route = try peerRoute(endpointID: "changed-endpoint")
        let statusProviderCalled = AsyncFlag()
        let probe = try await sentHostStatusProbe(
            route: route,
            stackAccessTokenForStatusProvider: {
                await statusProviderCalled.set()
                return "must-not-send"
            },
            irohEndpointTrustValidator: { _, _ in
                throw MobileShellConnectionError.irohEndpointChanged("endpoint changed")
            }
        )

        #expect(probe?.hasAuth == false)
        #expect(await statusProviderCalled.isSet() == false)
    }

    private func sentHostStatusProbe(
        route: CmxAttachRoute,
        stackAccessTokenForStatusProvider: @escaping @Sendable () async -> String?,
        irohEndpointTrustValidator: @escaping @Sendable (CmxAttachRoute, CmxAttachTicket) async throws -> Void
    ) async throws -> RecordedRPCRequest? {
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "test-stack-token",
            stackAccessTokenForStatusProvider: stackAccessTokenForStatusProvider,
            irohEndpointTrustValidator: irohEndpointTrustValidator
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-1",
            macDisplayName: "Mac",
            routes: [route]
        )
        let client = MobileCoreRPCClient(runtime: runtime, route: route, ticket: ticket, allowsStackAuthFallback: true)
        let task = Task {
            try await client.sendRequest(
                try MobileCoreRPCClient.requestData(method: "mobile.host.status")
            )
        }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value
        return sent.first
    }

    private func peerRoute(endpointID: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(id: endpointID, relayHint: nil, directAddrs: [], relayURL: nil),
            priority: 0
        )
    }
}
