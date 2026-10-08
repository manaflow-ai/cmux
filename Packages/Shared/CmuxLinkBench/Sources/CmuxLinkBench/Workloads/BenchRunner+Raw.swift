import CmuxLink
import Foundation

extension BenchRunner {
    /// Carrier-only throughput: host-to-dialer frames on the reliable bulk
    /// lane of a bare `LinkTransport`, with no `LinkSession` above it (no
    /// channel framing, acks or credit). Separates carrier cost from session cost.
    func rawDownload(recordBytes: Int) async throws -> ThroughputResult {
        let endpoints = try await rig.makeEndpoints()
        var dialed: (any LinkTransport)?
        var host: (any LinkTransport)?
        var sender: Task<Void, Never>?
        var receiver: Task<Void, Never>?

        do {
            let incoming = endpoints.acceptor.incoming
            async let accepted: (any LinkTransport)? = TimeLimit(.seconds(15)).run {
                for await transport in incoming { return transport }
                throw BenchError.setup("acceptor ended")
            }
            guard let carrier = endpoints.carriers.first else { throw BenchError.setup("no carrier") }
            let connected = try await carrier.connect(to: endpoints.peer)
            dialed = connected
            guard let acceptedHost = try await accepted else {
                throw BenchError.timeout("acceptor yielded no transport")
            }
            host = acceptedHost
            let lane = TransportLane(reliability: .reliableOrdered, priority: .bulk)
            let counter = ByteCounter()
            let warm = FirstResult<Bool>()
            sender = Task {
                let frame = TransportFrame(lane: lane, bytes: Data(count: recordBytes))
                while !Task.isCancelled {
                    guard (try? await acceptedHost.send(frame)) != nil else { return }
                }
            }
            receiver = Task {
                for await event in connected.events {
                    switch event {
                    case let .frame(frame):
                        counter.add(frame.bytes.count)
                        if counter.bytes >= 1 << 20 { await warm.resolve(.success(true)) }
                    case .closed:
                        await warm.resolve(.success(false))
                        return
                    default:
                        continue
                    }
                }
                await warm.resolve(.success(false))
            }
            guard try await TimeLimit(.seconds(15)).run({ try await warm.value() }) == true else {
                throw BenchError.timeout("raw warm-up (\(counter.bytes) bytes)")
            }
            let before = ProcessUsage()
            let bytesBefore = counter.bytes
            let start = clock.now
            try await Task.sleep(for: spec.transferWindow)
            let elapsed = clock.now - start
            let after = ProcessUsage()
            let received = counter.bytes - bytesBefore
            sender?.cancel()
            receiver?.cancel()
            await connected.close()
            await acceptedHost.close()
            await rig.tearDown()
            dialed = nil
            host = nil
            let cpu = after.cpuSeconds - before.cpuSeconds
            return ThroughputResult(
                recordBytes: recordBytes,
                priority: "bulk (raw transport)",
                receivedBytes: received,
                seconds: elapsed.milliseconds.rounded() / 1_000,
                megabitsPerSecond: Self.megabits(received, elapsed),
                cpuSeconds: (cpu * 1_000).rounded() / 1_000,
                cpuMillisecondsPerMiB: received > 0 ? (cpu * 1_000 / (Double(received) / 1_048_576) * 100).rounded() / 100 : 0
            )
        } catch {
            sender?.cancel()
            receiver?.cancel()
            await dialed?.close()
            await host?.close()
            await rig.tearDown()
            throw error
        }
    }
}
