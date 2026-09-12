import Foundation
import IrohLib
import Testing
@testable import CmuxNextTransport

@Suite("Named-lane adoption over live QUIC", .serialized)
struct IrohNamedLaneAdoptionTests {
    @Test("inbound adoption during an outgoing handshake keeps its stream",
          .timeLimit(.minutes(1)))
    func inboundAdoptionWinsBeforeOutgoingRegistration() async throws {
        let substrate = IrohSubstrate()
        let server = try await substrate.endpoint(
            identity: .generate(appIdentity: "adoption.host", deviceID: "host"),
            minimalLoopback: true)
        let client = try await substrate.endpoint(
            identity: .generate(appIdentity: "adoption.client", deviceID: "client"),
            minimalLoopback: true)
        let accepting = Task {
            let incoming = try #require(await server.acceptNext())
            let pending = try await incoming.accept()
            return try await pending.connect()
        }
        // A real test deadline closes native I/O, so even the regressed
        // unclosed duplicate cannot strand the runner in an FFI read.
        let deadline = Task {
            do { try await ContinuousClock().sleep(for: .seconds(20)) }
            catch { return }
            try? await server.close()
            try? await client.close()
        }
        do {
            let attempt = try client.beginConnect(
                addr: substrate.directAddr(of: server), alpn: substrate.alpn)
            let outgoing = try await attempt.connect()
            let incoming = try await accepting.value
            let peer = IrohPeerConnection(connection: outgoing, role: .dialer)
            let name = "colliding-lane"
            let open = Frame(type: IrohPeerConnection.laneOpenType,
                             payload: ["name": .string(name)])

            let candidate = try await outgoing.openBi()
            let candidateChannel = IrohLaneChannel(send: candidate.send(), recv: candidate.recv())
            try await candidateChannel.sendFrame(open)
            let remoteCandidate = try await incoming.acceptBi()
            let rejectedChannel = IrohLaneChannel(
                send: remoteCandidate.send(), recv: remoteCandidate.recv())
            #expect(await rejectedChannel.receiveOpenFrame() == open)

            // Drive the actual inbound parser before resuming the outgoing
            // post-handshake registration. This fixes the actor interleaving
            // deterministically without sleeps or a test-only scheduling hook.
            let first = try await incoming.openBi()
            let firstChannel = IrohLaneChannel(send: first.send(), recv: first.recv())
            try await firstChannel.sendFrame(open)
            let accepted = try await outgoing.acceptBi()
            await peer.processInboundStream(accepted, taskID: 1)
            let retained = try #require(await peer.lane(name) as? IrohLane)
            let returned = try await peer.completeNamedLaneOpen(
                name, stream: candidate, channel: candidateChannel)
            #expect(returned.token == retained.token)
            let registered = try #require(await peer.lane(name) as? IrohLane)
            #expect(registered.token == retained.token)

            let frame = Frame.dataChunk(seq: 1, data: Data("retained".utf8))
            try await retained.send(frame)
            #expect(await firstChannel.receiveFrame() == frame)
            try await firstChannel.sendFrame(frame)
            #expect(await retained.receive() == frame)
            // EOF must come from closing the duplicate, not our deadline
            // closing the entire connection. The winner stays usable.
            #expect(await rejectedChannel.receiveFrame() == nil)
            #expect(outgoing.closeReason() == nil)
            await peer.closeAll()
            deadline.cancel()
            await deadline.value
            try await server.close()
            try await client.close()
        } catch {
            deadline.cancel()
            accepting.cancel()
            try? await server.close()
            try? await client.close()
            await deadline.value
            _ = await accepting.result
            throw error
        }
    }
}
