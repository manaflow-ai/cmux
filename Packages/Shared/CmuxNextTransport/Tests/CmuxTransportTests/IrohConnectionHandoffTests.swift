import Foundation
import IrohLib
import Testing
@testable import CmuxNextTransport

@Suite("Native QUIC connection handoff", .serialized)
struct IrohConnectionHandoffTests {
    @Test("late cancellation closes the established connection", arguments: [
        IrohPeerConnection.Role.dialer, .acceptor
    ])
    func cancellationAfterHandshakeClosesConnection(role: IrohPeerConnection.Role) async throws {
        let substrate = IrohSubstrate()
        let server = try await substrate.endpoint(
            identity: .generate(appIdentity: "handoff.host", deviceID: "host"),
            minimalLoopback: true)
        let client = try await substrate.endpoint(
            identity: .generate(appIdentity: "handoff.client", deviceID: "client"),
            minimalLoopback: true)
        let accepting = Task {
            let incoming = try #require(await server.acceptNext())
            let pending = try await incoming.accept()
            return try await pending.connect()
        }
        do {
            let attempt = try client.beginConnect(
                addr: substrate.directAddr(of: server), alpn: substrate.alpn)
            let outgoing = try await attempt.connect()
            let incoming = try await accepting.value
            let connection: Connection
            switch role {
            case .dialer: connection = outgoing
            case .acceptor: connection = incoming
            }
            #expect(connection.closeReason() == nil)
            let handoff = Task {
                try await substrate.startPeer(role: role) {
                    // Deliver a real established connection after cancellation,
                    // exactly as a non-cooperative native handshake can do.
                    withUnsafeCurrentTask { $0?.cancel() }
                    return connection
                }
            }
            let result = await handoff.result
            #expect(connection.closeReason() != nil)
            switch result {
            case .failure(let error): #expect(error is CancellationError)
            case .success(let peer):
                Issue.record("A canceled handoff returned a live peer")
                await peer.closeAll()
            }
            try await server.close()
            try await client.close()
        } catch {
            accepting.cancel()
            try? await server.close()
            try? await client.close()
            _ = await accepting.result
            throw error
        }
    }

    @Test("a rejected handshake does not block the next accept", .timeLimit(.minutes(1)))
    func failedHandshakeLeavesEndpointUsable() async throws {
        let substrate = IrohSubstrate()
        let server = try await substrate.endpoint(
            identity: .generate(appIdentity: "accept.host", deviceID: "host"),
            minimalLoopback: true)
        let client = try await substrate.endpoint(
            identity: .generate(appIdentity: "accept.client", deviceID: "client"),
            minimalLoopback: true)
        // This is a real deadline, not a scheduling delay. Endpoint closure
        // unblocks the FFI if either handshake fails to make progress.
        let deadline = Task {
            do { try await ContinuousClock().sleep(for: .seconds(15)) }
            catch { return }
            try? await server.close()
            try? await client.close()
        }
        let invalidDial = Task {
            let attempt = try client.beginConnect(
                addr: substrate.directAddr(of: server), alpn: Data("unsupported-alpn".utf8))
            return try await attempt.connect()
        }
        var nextAccept: Task<IrohPeerConnection?, Error>?
        do {
            await #expect(throws: (any Error).self) {
                _ = try await substrate.acceptOne(endpoint: server)
            }
            switch await invalidDial.result {
            case .failure: break
            case .success(let connection):
                Issue.record("An unsupported ALPN was accepted")
                try connection.close(errorCode: 0, reason: Data())
            }
            let accepting = Task { try await substrate.acceptOne(endpoint: server) }
            nextAccept = accepting
            let dialer = try await substrate.dial(
                endpoint: client, to: substrate.directAddr(of: server))
            let acceptor = try #require(try await accepting.value)
            let outbound = await dialer.lane("after-failure")
            let inbound = await acceptor.lane("after-failure")
            let frame = Frame.dataChunk(seq: 1, data: Data("still-usable".utf8))
            try await outbound.send(frame)
            #expect(await inbound.receive() == frame)
            await dialer.closeAll()
            await acceptor.closeAll()
            deadline.cancel()
            await deadline.value
            try await server.close()
            try await client.close()
        } catch {
            deadline.cancel()
            invalidDial.cancel()
            nextAccept?.cancel()
            try? await server.close()
            try? await client.close()
            await deadline.value
            _ = await invalidDial.result
            _ = await nextAccept?.result
            throw error
        }
    }
}
