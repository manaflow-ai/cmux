import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCTransportDrainTests {
    @Test func disconnectDrainWaitsForPhysicalTransportClose() async throws {
        let transport = TransportDrainProbe()
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 59_124
        )
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport)
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
        let request = Task {
            try? await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "mobile.host.status",
                    id: "transport-drain-probe"
                )
            )
        }
        await transport.waitUntilSendStarted()

        let completion = TransportDrainCompletion()
        let drain = Task {
            await client.disconnectAndWaitForTransportDrain()
            await completion.finish()
        }
        await transport.waitUntilCloseStarted()
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(!(await completion.isFinished))

        await transport.releaseClose()
        await drain.value
        request.cancel()
        _ = await request.result
    }

    @Test func disconnectDrainReleasesAfterBoundedAbandonedCleanup()
        async throws {
        let transport = CancellationIgnoringConnectTransport()
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 59_125
        )
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport),
            rpcRequestTimeoutNanoseconds: 60_000_000_000
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
            allowsStackAuthFallback: true,
            abandonedConnectCleanupTimeoutNanoseconds: 1_000_000,
            lateAbandonedConnectCloseTimeoutNanoseconds: 1_000_000
        )
        let request = Task {
            try? await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "mobile.host.status",
                    id: "abandoned-connect-drain-probe"
                )
            )
        }
        #expect(await transport.waitUntilConnectCount(1))

        let completion = TransportDrainCompletion()
        let drain = Task {
            await client.disconnectAndWaitForTransportDrain()
            await completion.finish()
        }
        #expect(await transport.waitUntilCloseCount(1))
        await drain.value
        #expect(await completion.isFinished)

        await transport.releaseConnects()
        #expect(await transport.waitUntilCloseCount(2))
        request.cancel()
        _ = await request.result
    }
}
