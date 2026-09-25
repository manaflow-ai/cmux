import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// A silent control stream is not proof of a dead connection. Closing the
/// transport closes the whole QUIC connection, which also drops terminal
/// output and forces a full redial and replay. When the connection can still
/// carry a fresh stream, only the control stream is replaced.
@Suite struct MobileCoreRPCControlStreamRepairTests {
    private static let timeoutNanoseconds: UInt64 = 500_000_000

    private func makeClient(
        transport: any CmxByteTransport,
        port: Int
    ) throws -> MobileCoreRPCClient {
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: port)
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport),
            rpcRequestTimeoutNanoseconds: Self.timeoutNanoseconds
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

    private func request(method: String, id: String, params: [String: Any] = [:]) throws -> Data {
        var merged: [String: Any] = ["workspace_id": "workspace-main", "surface_id": "surface-main"]
        merged.merge(params) { _, new in new }
        return try MobileCoreRPCClient.requestData(method: method, params: merged, id: id)
    }

    @Test func aSilentStreamOnALiveConnectionIsReplacedWithoutClosingTheConnection() async throws {
        let transport = RepairableSilentTransport(repairOutcome: .repaired(generation: 1))
        let client = try makeClient(transport: transport, port: 59320)

        async let first: Void = {
            do {
                _ = try await client.sendRequest(try request(method: "mobile.terminal.replay", id: "replay-1"))
                Issue.record("Expected the request that exposed the silence to time out")
            } catch {}
        }()
        await transport.waitUntilSent(count: 1)
        // Written later, so still outstanding when the first deadline passes.
        try await Task.sleep(for: .milliseconds(150))
        async let listed = client.sendRequest(try request(method: "mobile.workspace.list", id: "list-1"))
        await transport.waitUntilSent(count: 2)
        async let typed: Void = {
            do {
                _ = try await client.sendRequest(
                    try request(method: "terminal.input", id: "input-1", params: ["text": "ls\n"])
                )
                Issue.record("A mutation written to the silent stream must not be answered by a resend")
            } catch {}
        }()
        await transport.waitUntilSent(count: 3)

        await first
        // The idempotent read that was stranded on the silent stream is
        // resent on the replacement and answered.
        _ = try await listed
        await typed

        #expect(await transport.closed() == false)
        #expect(await transport.repairCount == 1)
        let sent = await transport.sentRequests()
        #expect(sent.filter { $0.id == "list-1" }.map(\.generation) == [0, 1])
        // Never replayed: it may already have been applied by the host.
        #expect(sent.filter { $0.id == "input-1" }.count == 1)
        // The replacement was verified with a request the host answered.
        #expect(sent.contains { $0.generation == 1 && $0.method == "mobile.events.probe" })
    }

    @Test func positiveEvidenceOfAWhollySilentConnectionRedialsOnTheFirstTimeout() async throws {
        let transport = RepairableSilentTransport(repairOutcome: .connectionSilent)
        let client = try makeClient(transport: transport, port: 59321)

        do {
            _ = try await client.sendRequest(try request(method: "mobile.terminal.replay", id: "replay-1"))
            Issue.record("Expected the replay to fail")
        } catch {}

        #expect(await transport.waitUntilClosed())
        #expect(await transport.repairCount == 1)
    }

    @Test func aReplacementThatNeverAnswersEscalatesToRedial() async throws {
        let transport = RepairableSilentTransport(
            repairOutcome: .repaired(generation: 1),
            replacementAnswers: false
        )
        let client = try makeClient(transport: transport, port: 59322)

        do {
            _ = try await client.sendRequest(try request(method: "mobile.terminal.replay", id: "replay-1"))
            Issue.record("Expected the replay to fail")
        } catch {}

        #expect(await transport.waitUntilClosed())
        // Exactly one replacement per connection before escalation.
        #expect(await transport.repairCount == 1)
    }

    @Test func withoutConclusiveEvidenceTheConservativeThresholdStillApplies() async throws {
        let transport = RepairableSilentTransport(repairOutcome: .unavailable)
        let client = try makeClient(transport: transport, port: 59323)

        do {
            _ = try await client.sendRequest(try request(method: "mobile.terminal.replay", id: "replay-1"))
            Issue.record("Expected the replay to fail")
        } catch {}
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.closed() == false)
        #expect(await transport.repairCount == 1)

        do {
            _ = try await client.sendRequest(try request(method: "mobile.terminal.replay", id: "replay-2"))
            Issue.record("Expected the retry to fail")
        } catch {}

        #expect(await transport.waitUntilClosed())
        #expect(await transport.repairCount == 1)
    }
}
