import CmuxLink
import CmuxLinkTesting
@_spi(Testing) import CmuxLinkWebRTC
import Foundation
import os
import Testing

/// D2 finding F1 (d2-bakeoff.md): large data channel messages overflowed
/// the receiving UDP socket, dcSCTP's loss recovery stalled the whole
/// association, and the input lane waited seconds behind bulk.
@Suite("Large frames", .serialized)
struct LargeFrameTests {
    static let input = TransportLane(reliability: .reliableOrdered, priority: .input)
    static let bulk = TransportLane(reliability: .reliableOrdered, priority: .bulk)

    @Test("256 KiB bulk frames keep a 64 B echo under 250 ms p99 and all arrive")
    func bulkDoesNotStallInput() async throws {
        let pair = await WebRTCPair()
        let (dialer, host) = try await within { try await pair.connect() }
        let frameBytes = TransportCapabilities.stream.maxFrameBytes
        let bulkFrames = 64 // 16 MiB
        let received = OSAllocatedUnfairLock(initialState: 0)
        let (bulkDone, bulkDoneSink) = AsyncStream.makeStream(of: Void.self)
        let echoes = AsyncQueue<Data>()

        // Host: count bulk frames, echo input frames.
        let hostLoop = Task {
            for await event in host.events {
                guard case let .frame(frame) = event else { continue }
                if frame.lane == Self.input {
                    try? await host.send(frame)
                } else if frame.bytes.count == frameBytes {
                    if received.withLock({ $0 += 1; return $0 }) == bulkFrames { bulkDoneSink.yield() }
                }
            }
        }
        let dialerLoop = Task {
            for await event in dialer.events {
                if case let .frame(frame) = event, frame.lane == Self.input { await echoes.push(frame.bytes) }
            }
        }
        let sender = Task {
            let chunk = Data(repeating: 0xAB, count: frameBytes)
            for _ in 0..<bulkFrames { try await dialer.send(TransportFrame(lane: Self.bulk, bytes: chunk)) }
        }

        var samples: [Duration] = []
        let clock = ContinuousClock()
        for index in 0..<100 {
            let started = clock.now
            try await dialer.send(TransportFrame(lane: Self.input, bytes: Data(repeating: UInt8(index), count: 64)))
            let echoed = try await within(.seconds(15)) { await echoes.next() }
            samples.append(clock.now - started)
            #expect(echoed?.count == 64)
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try await within(.seconds(60)) {
            for await _ in bulkDone { return true }
            return false
        }
        sender.cancel()
        hostLoop.cancel()
        dialerLoop.cancel()
        let sorted = samples.sorted()
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        print("echo under 256 KiB bulk: p50 \(sorted[sorted.count / 2]) p99 \(p99); bulk frames \(received.withLock { $0 })")
        #expect(p99 < .milliseconds(250))
        await dialer.close()
        await pair.stop()
    }
}
