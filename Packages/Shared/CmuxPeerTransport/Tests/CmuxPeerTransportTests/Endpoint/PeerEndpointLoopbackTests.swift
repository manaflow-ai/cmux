import Foundation
import Testing

import CmuxPeerTransportCore

@testable import CmuxPeerTransport

/// The crown jewel: two live PeerEndpointManagers in one process (relays
/// disabled, direct-only), endpoint A accepting through PeerInboundListener,
/// endpoint B dialing A's ID with A's loopback addresses as hints, one bi
/// stream opened from each side, bytes exchanged, clean close.
@Suite("PeerEndpoint loopback", .serialized)
struct PeerEndpointLoopbackTests {
    struct LoopbackFailure: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    @Test(.timeLimit(.minutes(3)))
    func loopbackBiDirectionalExchange() async throws {
        // Real sockets and a real QUIC handshake: allow one retry so a
        // transient local-network hiccup cannot fail the suite, but the test
        // itself never gets skipped or weakened.
        var lastError: any Error = LoopbackFailure(reason: "never ran")
        for attempt in 1...2 {
            do {
                try await runLoopbackExchange()
                return
            } catch {
                lastError = error
                if attempt == 1 {
                    try await ContinuousClock().sleep(for: .milliseconds(500))
                }
            }
        }
        throw lastError
    }

    private func runLoopbackExchange() async throws {
        let managerA = PeerEndpointManager()
        let managerB = PeerEndpointManager()
        do {
            try await exchange(managerA: managerA, managerB: managerB)
        } catch {
            await managerA.deactivate()
            await managerB.deactivate()
            throw error
        }
        await managerA.deactivate()
        await managerB.deactivate()
    }

    private func exchange(
        managerA: PeerEndpointManager,
        managerB: PeerEndpointManager
    ) async throws {
        let generationA = try await managerA.activate(
            secretKey: EndpointTestSupport.randomSecret(),
            relays: [],
            directOnly: true
        )
        let generationB = try await managerB.activate(
            secretKey: EndpointTestSupport.randomSecret(),
            relays: [],
            directOnly: true
        )

        let hostDone = TestCompletionBox()
        let listener = PeerInboundListener(
            manager: managerA,
            maxConcurrentUnauthenticated: 4
        ) { connection in
            await Self.runHostSide(connection: connection, done: hostDone)
        }
        try await listener.start(generation: generationA)

        guard let endpointIDA = await managerA.endpointID else {
            throw LoopbackFailure(reason: "manager A has no endpointID")
        }
        let hints = await EndpointTestSupport.loopbackHints(for: managerA)
        try #require(!hints.isEmpty, "no loopback dial hints for manager A")

        let dialer = PeerConnectionDialer(manager: managerB)
        let connection = try await dialer.dial(
            endpointID: endpointIDA,
            directHints: hints,
            generation: generationB,
            timeout: .seconds(30)
        )
        #expect(connection.remoteEndpointID == endpointIDA)

        // Stream 1, opened by B: request/response.
        let outbound = try await connection.openBi()
        try await outbound.write(Data("hello-from-B".utf8))
        try await outbound.finish()
        let reply = try await outbound.readToEnd()
        #expect(String(decoding: reply, as: UTF8.self) == "A-saw:hello-from-B")

        // Stream 2, opened by A: reverse-direction request/response.
        let inbound = try await connection.acceptBi()
        let fromA = try await inbound.readToEnd()
        #expect(String(decoding: fromA, as: UTF8.self) == "hello-from-A")
        try await inbound.write(Data("B-ack".utf8))
        try await inbound.finish()

        // The host side saw exactly the same protocol.
        try await hostDone.awaitCompletion()

        // Route diagnostics on a direct-only loopback connection must not
        // report a relay route.
        let diagnostics = connection.routeDiagnostics()
        #expect(diagnostics.routeClass != .relay)

        // Clean close, observed on the accept side.
        connection.close(reason: "loopback-test-done")
        await listener.stop()
    }

    private static func runHostSide(
        connection: PeerQuicConnection,
        done: TestCompletionBox
    ) async {
        do {
            // Stream 1 (B-initiated): read the request, answer, finish.
            let inbound = try await connection.acceptBi()
            let request = try await inbound.readToEnd()
            guard String(decoding: request, as: UTF8.self) == "hello-from-B" else {
                throw LoopbackFailure(
                    reason: "unexpected request: \(String(decoding: request, as: UTF8.self))"
                )
            }
            try await inbound.write(Data("A-saw:".utf8) + request)
            try await inbound.finish()

            // Stream 2 (A-initiated): send, await the ack.
            let outbound = try await connection.openBi()
            try await outbound.write(Data("hello-from-A".utf8))
            try await outbound.finish()
            let ack = try await outbound.readToEnd()
            guard String(decoding: ack, as: UTF8.self) == "B-ack" else {
                throw LoopbackFailure(
                    reason: "unexpected ack: \(String(decoding: ack, as: UTF8.self))"
                )
            }
            await done.complete(with: .success(()))

            // Observe the client's clean close so the handler exits with the
            // connection, proving close propagates across the loopback.
            _ = await connection.awaitClosed()
        } catch {
            await done.complete(with: .failure(error))
        }
    }
}
