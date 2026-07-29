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

    @Test func disconnectDrainWaitsForAbandonedConnectingCandidate()
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
            allowsStackAuthFallback: true
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
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(!(await completion.isFinished))

        await transport.releaseConnects()
        await drain.value
        #expect(await transport.closeCount() >= 2)
        request.cancel()
        _ = await request.result
    }
}

private actor TransportDrainCompletion {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}

private actor TransportDrainProbe: CmxByteTransport {
    private var sendStarted = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeStarted = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeReleased = false
    private var closeReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {}

    func receive() async throws -> Data? {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return nil
    }

    func send(_ data: Data) async throws {
        _ = data
        sendStarted = true
        for waiter in sendWaiters { waiter.resume() }
        sendWaiters = []
    }

    func close() async {
        closeStarted = true
        for waiter in closeWaiters { waiter.resume() }
        closeWaiters = []
        guard !closeReleased else { return }
        await withCheckedContinuation {
            closeReleaseWaiters.append($0)
        }
    }

    func waitUntilSendStarted() async {
        if sendStarted { return }
        await withCheckedContinuation { sendWaiters.append($0) }
    }

    func waitUntilCloseStarted() async {
        if closeStarted { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    func releaseClose() {
        closeReleased = true
        for waiter in closeReleaseWaiters { waiter.resume() }
        closeReleaseWaiters = []
    }
}
