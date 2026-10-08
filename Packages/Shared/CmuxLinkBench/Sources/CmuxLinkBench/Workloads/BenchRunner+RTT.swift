import CmuxLink
import Foundation

extension BenchRunner {
    /// Sequential 64 B echoes on an idle link.
    func rttIdle() async throws -> Distribution {
        try await withFixture { fixture in
            let echo = try await EchoChannel.open(on: fixture)
            let samples = try await pings(echo)
            await echo.close()
            return Distribution(milliseconds: samples)
        }
    }

    /// The same echoes while a bulk download saturates the link.
    func rttUnderBulk() async throws -> RTTUnderBulkResult {
        try await withFixture { fixture in
            let echo = try await EchoChannel.open(on: fixture)
            let descriptor = ChannelDescriptor(stream: "bench/bulk-bg", reliability: .reliableOrdered, priority: .bulk)
            let pair = try await fixture.openPair(descriptor)
            let local = pair.local
            let counter = ByteCounter()
            let flowing = FirstResult<Bool>()
            let threshold = 2 << 20
            let sender = pair.remote.map { remote in
                Task {
                    let chunk = Data(count: spec.bulkRecordBytes)
                    while !Task.isCancelled {
                        guard (try? await remote.send(chunk)) != nil else { return }
                    }
                }
            }
            let receiver = Task {
                for await event in local.events {
                    guard case let .message(message) = event else { if case .closed = event { break }; continue }
                    counter.add(message.payload.count)
                    if counter.bytes >= threshold { await flowing.resolve(.success(true)) }
                }
                await flowing.resolve(.success(false))
            }
            _ = try await TimeLimit(.seconds(5)).run { try await flowing.value() }
            let bytesBefore = counter.bytes
            let start = clock.now
            let samples = try await pings(echo)
            let window = clock.now - start
            let bulkBytes = counter.bytes - bytesBefore
            sender?.cancel()
            receiver.cancel()
            await local.close()
            await echo.close()
            return RTTUnderBulkResult(
                rtt: Distribution(milliseconds: samples),
                bulkMegabitsPerSecond: Self.megabits(bulkBytes, window)
            )
        }
    }

    /// Echo samples until the budget or the sample cap; at least 10.
    func pings(_ echo: EchoChannel) async throws -> [Double] {
        // Warm-up: the first echo on a channel pays for lazy setup.
        _ = try await echo.ping()
        var samples: [Double] = []
        let start = clock.now
        while samples.count < spec.rttMaxSamples, samples.count < 10 || clock.now - start < spec.rttBudget {
            guard let rtt = try await echo.ping() else { throw BenchError.timeout("echo \(samples.count)") }
            samples.append(rtt.milliseconds)
        }
        return samples
    }

    static func megabits(_ bytes: Int, _ duration: Duration) -> Double {
        let seconds = duration.milliseconds / 1_000
        guard seconds > 0 else { return 0 }
        return (Double(bytes) * 8 / 1e6 / seconds * 10).rounded() / 10
    }
}
