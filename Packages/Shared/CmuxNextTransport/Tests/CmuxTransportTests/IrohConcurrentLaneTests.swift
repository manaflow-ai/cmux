import Foundation
import Testing
@testable import CmuxNextTransport

@Suite("Concurrent named lanes over live QUIC", .serialized)
struct IrohConcurrentLaneTests {
    @Test("cancelled callers cannot consume an existing live lane", .timeLimit(.minutes(1)))
    func cancelledCallerCannotTakeLiveLane() async throws {
        let substrate = IrohSubstrate()
        let server = try await substrate.endpoint(
            identity: .generate(appIdentity: "cancel.host", deviceID: "host"),
            minimalLoopback: true)
        let client = try await substrate.endpoint(
            identity: .generate(appIdentity: "cancel.client", deviceID: "client"),
            minimalLoopback: true)
        let accepting = Task { try await substrate.acceptOne(endpoint: server) }
        do {
            let dialer = try await substrate.dial(
                endpoint: client, to: substrate.directAddr(of: server))
            let acceptor = try #require(try await accepting.value)
            let local = await dialer.lane("cancelled-consumer")
            let remote = await acceptor.lane("cancelled-consumer")
            for peer in [dialer, acceptor] {
                let cancelled = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return await peer.lane("cancelled-consumer")
                }
                let returned = await cancelled.value
                await #expect(throws: TransportError.pipeClosed) {
                    try await returned.send(Frame.dataChunk(seq: 0, data: Data([0])))
                }
            }
            // Prove cancellation did not close/reset the shared lane.
            let frame = Frame.dataChunk(seq: 1, data: Data([1]))
            try await local.send(frame)
            #expect(await remote.receive() == frame)
            await dialer.closeAll()
            await acceptor.closeAll()
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

    @Test("concurrent callers share one usable stream on both peers", .timeLimit(.minutes(1)))
    func sameNameSharesAUsableStream() async throws {
        let substrate = IrohSubstrate()
        let server = try await substrate.endpoint(
            identity: .generate(appIdentity: "lane-test.host", deviceID: "host"),
            minimalLoopback: true)
        let client = try await substrate.endpoint(
            identity: .generate(appIdentity: "lane-test.client", deviceID: "client"),
            minimalLoopback: true)
        let accepting = Task { try await substrate.acceptOne(endpoint: server) }
        do {
            let dialer = try await substrate.dial(
                endpoint: client, to: substrate.directAddr(of: server))
            let acceptor = try #require(try await accepting.value)
            // A genuine test deadline closes QUIC, unblocking any native read
            // if the regression strands the peers on mismatched streams.
            let deadline = Task {
                do { try await ContinuousClock().sleep(for: .seconds(15)) }
                catch { return }
                await dialer.closeAll()
                await acceptor.closeAll()
            }
            do {
                for round in 0..<8 {
                    let name = "concurrent-\(round)"
                    let lanes = await withTaskGroup(of: (any TransportLane).self) { group in
                        for _ in 0..<32 { group.addTask { await dialer.lane(name) } }
                        var opened: [any TransportLane] = []
                        for await lane in group { opened.append(lane) }
                        return opened
                    }
                    let native = try lanes.map { try #require($0 as? IrohLane) }
                    #expect(Set(native.map(\.token)).count == 1)
                    let remote = await acceptor.lane(name)
                    // Exercise every returned handle, not just dictionary
                    // membership: local and remote must agree on the stream.
                    for (index, lane) in lanes.enumerated() {
                        let frame = Frame.dataChunk(seq: Int64(index), data: Data([1, 2, 3]))
                        try await lane.send(frame)
                        let received = try #require(await remote.receive())
                        #expect(received == frame)
                    }
                    let reply = Frame.dataChunk(seq: Int64(round), data: Data([4, 5, 6]))
                    try await remote.send(reply)
                    #expect(await lanes[0].receive() == reply)
                }
                deadline.cancel()
                await deadline.value
                await dialer.closeAll()
                await acceptor.closeAll()
            } catch {
                deadline.cancel()
                await deadline.value
                await dialer.closeAll()
                await acceptor.closeAll()
                throw error
            }
            try await server.close()
            try await client.close()
        } catch {
            accepting.cancel()
            try? await server.close()
            try? await client.close()
            _ = try? await accepting.value
            throw error
        }
    }
}
