import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// A QUIC path can stop carrying traffic without closing: `receive()` never
/// returns and never throws, so the read loop cannot tear the connection down.
/// Every request then rides that corpse until its own deadline, and because
/// the deadline failed only the request, the retry rode it again. Two of those
/// is a minute of blank terminal on the phone.
@Suite struct MobileCoreRPCSilentTransportTests {
    private func makeClient(
        transport: any CmxByteTransport,
        port: Int,
        timeoutNanoseconds: UInt64 = 200_000_000
    ) throws -> MobileCoreRPCClient {
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: port)
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport),
            rpcRequestTimeoutNanoseconds: timeoutNanoseconds
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
        return MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
    }

    private func replayRequest(id: String) throws -> Data {
        try MobileCoreRPCClient.requestData(
            method: "mobile.terminal.replay",
            params: ["workspace_id": "workspace-main", "surface_id": "surface-main"],
            id: id
        )
    }

    @Test func aTransportThatDeliversNothingIsCondemnedOnTheSecondTimeout() async throws {
        let transport = ControllableResponseTransport(closeEndsReceive: true)
        let client = try makeClient(transport: transport, port: 59310)

        do {
            _ = try await client.sendRequest(try replayRequest(id: "replay-1"))
            Issue.record("Expected the first replay to fail")
        } catch {}
        // One unanswered request is ambiguous; the connection survives it.
        #expect(await transport.closed() == false)

        do {
            _ = try await client.sendRequest(try replayRequest(id: "replay-2"))
            Issue.record("Expected the retry to fail")
        } catch {}

        // Both writes succeeded and the transport never reported itself
        // closed, so nothing else in the session could condemn it. Two
        // written requests answered by total silence is the evidence.
        #expect(await transport.closed())
    }

    /// Six replays fired together and answered by one quiet period is one
    /// piece of evidence, not six. Without a silence-window guard a single
    /// quiet moment condemns the transport on concurrent requests alone.
    @Test func concurrentTimeoutsInOneSilenceWindowAreOnePieceOfEvidence() async throws {
        let transport = ControllableResponseTransport(closeEndsReceive: true)
        let client = try makeClient(transport: transport, port: 59312)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    _ = try? await client.sendRequest(
                        try self.replayRequest(id: "concurrent-\(index)")
                    )
                }
            }
            await group.waitForAll()
        }

        #expect(await transport.closed() == false)
    }

    /// The guard that keeps this from punishing a healthy connection: if
    /// anything at all arrived while the request was outstanding, the lane is
    /// demonstrably alive and only the request failed.
    @Test func aTransportStillDeliveringIsKeptWhenOneRequestTimesOut() async throws {
        let transport = ControllableResponseTransport(closeEndsReceive: true)
        let client = try makeClient(transport: transport, port: 59311)

        async let outcome: Void = {
            do {
                _ = try await client.sendRequest(try replayRequest(id: "replay-2"))
                Issue.record("Expected the replay to fail")
            } catch {}
        }()

        await transport.waitUntilSent(count: 1)
        // Unrelated inbound traffic: proves the lane still carries bytes even
        // though this request is never answered.
        try await transport.deliverResponse(id: "someone-else", status: "ok")
        await outcome

        #expect(await transport.closed() == false)
    }
}
