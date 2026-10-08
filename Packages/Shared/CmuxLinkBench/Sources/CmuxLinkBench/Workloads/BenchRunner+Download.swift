import CmuxLink
import Foundation

extension BenchRunner {
    /// Host-to-dialer stream of `recordBytes` messages on a reliable channel
    /// at `priority`. After 1 MiB of warm-up, counts what the dialer consumes
    /// over the spec's measurement window (steady-state throughput).
    func download(stream: String, priority: ChannelPriority, recordBytes: Int) async throws -> ThroughputResult {
        try await withFixture { fixture in
            let descriptor = ChannelDescriptor(stream: stream, reliability: .reliableOrdered, priority: priority)
            let pair = try await fixture.openPair(descriptor)
            let local = pair.local
            let counter = ByteCounter()
            let warm = FirstResult<Bool>()
            let warmup = 1 << 20
            let sender = pair.remote.map { remote in
                Task {
                    let chunk = Data(count: recordBytes)
                    while !Task.isCancelled {
                        guard (try? await remote.send(chunk)) != nil else { return }
                    }
                }
            }
            let receiver = Task {
                for await event in local.events {
                    guard case let .message(message) = event else { if case .closed = event { break }; continue }
                    counter.add(message.payload.count)
                    if counter.bytes >= warmup { await warm.resolve(.success(true)) }
                }
                await warm.resolve(.success(false))
            }
            defer {
                sender?.cancel()
                receiver.cancel()
            }
            guard try await TimeLimit(.seconds(15)).run({ try await warm.value() }) == true else {
                throw BenchError.timeout("warm-up (\(counter.bytes) bytes in 15 s)")
            }
            let before = ProcessUsage()
            let bytesBefore = counter.bytes
            let start = clock.now
            try await Task.sleep(for: spec.transferWindow)
            let elapsed = clock.now - start
            let after = ProcessUsage()
            let received = counter.bytes - bytesBefore
            await local.close()
            let cpu = after.cpuSeconds - before.cpuSeconds
            return ThroughputResult(
                recordBytes: recordBytes,
                priority: "\(priority)",
                receivedBytes: received,
                seconds: (elapsed.milliseconds).rounded() / 1_000,
                megabitsPerSecond: Self.megabits(received, elapsed),
                cpuSeconds: (cpu * 1_000).rounded() / 1_000,
                cpuMillisecondsPerMiB: received > 0 ? (cpu * 1_000 / (Double(received) / 1_048_576) * 100).rounded() / 100 : 0
            )
        }
    }
}
