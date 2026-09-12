import Foundation
import Testing
@testable import CmuxNextTransport

@Suite("Remote QUIC closure ownership", .serialized)
struct IrohRemoteClosureTests {
    @Test("control lane EOF does not wait for a live QUIC close",
          .timeLimit(.minutes(1)))
    func controlLaneEOFDoesNotWaitForConnectionClose() async throws {
        let substrate = IrohSubstrate()
        let server = try await substrate.endpoint(
            identity: .generate(appIdentity: "eof.host", deviceID: "host"),
            minimalLoopback: true)
        let client = try await substrate.endpoint(
            identity: .generate(appIdentity: "eof.client", deviceID: "client"),
            minimalLoopback: true)
        let accepting = Task { try await substrate.acceptOne(endpoint: server) }
        defer {
            accepting.cancel()
            Task {
                try? await server.close()
                try? await client.close()
            }
        }

        let dialer = try await substrate.dial(
            endpoint: client, to: substrate.directAddr(of: server))
        let acceptor = try #require(try await accepting.value)
        let outgoing = try #require(await dialer.lane("ctl") as? IrohLane)
        let incoming = try #require(await acceptor.lane("ctl") as? IrohLane)

        await outgoing.finishSend()
        #expect(await incoming.receive() == nil)
        #expect(await acceptor.isClosed == false)

        // A stream can finish while its QUIC connection remains live. The
        // owner must classify that lane EOF promptly instead of waiting for a
        // connection close that may never arrive. The timeout branch closes
        // the connection only to release a regressed implementation's wait.
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await acceptor.terminationAfterLaneEOF()
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return true }
                await acceptor.closeAll()
                return true
            }
            let result = await group.next() ?? true
            group.cancelAll()
            return result
        }
        #expect(!timedOut)

        await acceptor.closeAll()
        await dialer.closeAll()
    }

    @Test("remote closure preserves its reason and cancels owned raw delivery",
          .timeLimit(.minutes(1)), arguments: [
            CloseReason.superseded.code, DenialCode.revoked.rawValue,
            CloseReason.grantExpired.code,
          ])
    func remoteClosureCancelsDelivery(code: String) async throws {
        let substrate = IrohSubstrate()
        let server = try await substrate.endpoint(
            identity: .generate(appIdentity: "closure.host", deviceID: "host"),
            minimalLoopback: true)
        let client = try await substrate.endpoint(
            identity: .generate(appIdentity: "closure.client", deviceID: "client"),
            minimalLoopback: true)
        let accepting = Task { try await substrate.acceptOne(endpoint: server) }
        let started = AsyncStream.makeStream(of: Void.self)
        let blocked = AsyncStream.makeStream(of: Void.self)
        defer { blocked.continuation.finish() }
        do {
            let dialer = try await substrate.dial(
                endpoint: client, to: substrate.directAddr(of: server))
            let acceptor = try #require(try await accepting.value)
            await acceptor.onRawStream { _, _ in
                started.continuation.finish()
                for await _ in blocked.stream {}
            }
            _ = try await dialer.openRawStream(preamble: "blocked-handler")
            for await _ in started.stream {}
            let delivery = try #require(await acceptor.rawDeliveryTask)

            await dialer.closeAll(reason: ConnectionTermination(code: code))
            // An unknown named lane returns EOF only after the accept loop
            // has observed the closed stream source and retired its waiters.
            let ended = await acceptor.lane("after-remote-close")
            await #expect(throws: TransportError.pipeClosed) {
                try await ended.send(Frame.dataChunk(seq: 0, data: Data()))
            }
            #expect(await acceptor.termination() == ConnectionTermination(code: code))
            #expect(delivery.isCancelled)
            await acceptor.closeAll()
            #expect(delivery.isCancelled)
            #expect(await acceptor.rawDeliveryTask == nil)

            // Release even the regressed handler, so red assertions do not
            // strand a task or turn this regression into a timeout test.
            blocked.continuation.finish()
            await delivery.value
            try await server.close()
            try await client.close()
        } catch {
            blocked.continuation.finish()
            accepting.cancel()
            try? await server.close()
            try? await client.close()
            _ = await accepting.result
            throw error
        }
    }
}
