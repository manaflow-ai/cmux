import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCManualHostTrustTests {
    @Test func revokingTrustBlocksTokenBearingWriteAlreadyQueuedBehindBlockedSend() async throws {
        let route = try hostPortRoute(kind: .manualHost, host: "192.168.1.20", port: 58_465)
        let scope = try #require(
            MobileManualHostTrustScope(route: route, stackUserID: "phone-user")
        )
        let trustStore = InMemoryMobileManualHostTrustStore()
        await trustStore.trust(scope)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "trusted-manual-token",
            rpcRequestTimeoutNanoseconds: 60 * 1_000_000_000
        )
        let client = MobileCoreRPCClient.testClient(
            runtime: runtime,
            route: route,
            ticket: try qrPairingTicket(route: route),
            allowsStackAuthFallback: true,
            manualHostStackAuthTrustProvider: {
                await trustStore.isTrusted(scope)
            }
        )
        let blockingID = "trusted-blocking-write"
        let queuedID = "revoked-queued-write"
        let blockingRequest = try MobileCoreRPCClient.requestData(
            method: "workspace.list",
            id: blockingID
        )
        let queuedRequest = try MobileCoreRPCClient.requestData(
            method: "workspace.list",
            id: queuedID
        )

        let blockingTask = Task { try await client.sendRequest(blockingRequest) }
        let initiallySent = try await transport.waitForSentRequestCount(1)
        #expect(initiallySent.map(\.id) == [blockingID])

        let queuedTask = Task { try await client.sendRequest(queuedRequest) }
        for _ in 0..<1_000 {
            if await client.session.queuedRequestIDs.contains(queuedID) { break }
            await Task.yield()
        }
        #expect(await client.session.queuedRequestIDs.contains(queuedID))

        await trustStore.removeAll()
        await transport.releaseFirstSend()
        for _ in 0..<1_000 {
            if !(await client.session.queuedRequestIDs.contains(queuedID)) { break }
            await Task.yield()
        }

        #expect(!(await client.session.queuedRequestIDs.contains(queuedID)))
        #expect(try await transport.sentRequests().map(\.id) == [blockingID])

        queuedTask.cancel()
        blockingTask.cancel()
        _ = try? await queuedTask.value
        _ = try? await blockingTask.value
    }

    @Test func revokingTrustBlocksNextRequestOnExistingManualHostClient() async throws {
        let route = try hostPortRoute(kind: .manualHost, host: "192.168.1.20", port: 58_465)
        let scope = try #require(
            MobileManualHostTrustScope(route: route, stackUserID: "phone-user")
        )
        let trustStore = InMemoryMobileManualHostTrustStore()
        await trustStore.trust(scope)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "trusted-manual-token"
        )
        let client = MobileCoreRPCClient.testClient(
            runtime: runtime,
            route: route,
            ticket: try qrPairingTicket(route: route),
            allowsStackAuthFallback: true,
            manualHostStackAuthTrustProvider: {
                await trustStore.isTrusted(scope)
            }
        )
        let request = try MobileCoreRPCClient.requestData(method: "workspace.list")
        let trustedRequest = Task { try await client.sendRequest(request) }
        let sentWhileTrusted = try await transport.waitForSentRequestCount(1)
        trustedRequest.cancel()
        _ = try? await trustedRequest.value

        #expect(sentWhileTrusted.first?.stackAccessToken == "trusted-manual-token")

        await trustStore.removeAll()

        do {
            _ = try await client.sendRequest(request)
            Issue.record("Expected revoked manual-host trust to block Stack auth")
        } catch let error as MobileShellConnectionError {
            guard case .insecureManualRoute = error else {
                Issue.record("Expected insecureManualRoute, got \(error)")
                return
            }
        }
        #expect(try await transport.sentRequests().count == 1)
    }

    private func qrPairingTicket(route: CmxAttachRoute) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: nil,
            authToken: nil
        )
    }
}
