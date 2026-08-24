import Foundation
import Testing

@testable import CmuxNextTransport

@Suite("Lanes (contract 5.x)")
struct LaneTests {
    @Test("Per-lane ordering is lossless across 500 interleaved chunks (5.1)")
    func orderedLossless() async throws {
        let (client, hostEnd) = LoopbackWire(laneCapacity: 16).makeEnds()
        let sender = await client.lane("data-1")
        let receiver = await hostEnd.lane("data-1")

        let production = Task {
            for seq in Int64(0)..<500 {
                try await sender.send(TerminalTraffic.chunk(seq: seq, size: 256, seed: 7))
            }
        }
        var validator = TrafficValidator()
        for _ in 0..<500 {
            if let frame = await receiver.receive() {
                validator.ingest(frame)
            }
        }
        try await production.value
        #expect(validator.received == 500)
        #expect(validator.isClean)
    }

    @Test("A wedged lane stalls only its own sender; other lanes keep flowing (5.2, 5.3)")
    func wedgedLaneDoesNotBlockOthers() async throws {
        let capacity = 8
        let (client, hostEnd) = LoopbackWire(laneCapacity: capacity).makeEnds()
        // Lane "wedged": the reader never reads. The old stack's single
        // serialized writer would have parked ALL traffic here (issue 8005).
        let wedgedSender = await client.lane("wedged")
        _ = await hostEnd.lane("wedged")  // reader exists but never reads

        // Fill the wedged lane to capacity; none of these suspend.
        for seq in Int64(0)..<Int64(capacity) {
            try await wedgedSender.send(TerminalTraffic.chunk(seq: seq, size: 64, seed: 1))
        }
        // The next send MUST suspend (real backpressure), not fail, not drop,
        // and must not close anything (5.3).
        let overflowSend = Task {
            try await wedgedSender.send(
                TerminalTraffic.chunk(seq: Int64(capacity), size: 64, seed: 1))
        }

        // Meanwhile the healthy lane round-trips 200 chunks untouched (5.2).
        let healthySender = await client.lane("healthy")
        let healthyReceiver = await hostEnd.lane("healthy")
        var validator = TrafficValidator()
        for seq in Int64(0)..<200 {
            try await healthySender.send(TerminalTraffic.chunk(seq: seq, size: 128, seed: 2))
            if let frame = await healthyReceiver.receive() {
                validator.ingest(frame)
            }
        }
        #expect(validator.received == 200)
        #expect(validator.isClean)

        // The wedged sender is in a recorded backpressure stall, still alive.
        var stalls = await wedgedSender.backpressureStalls
        var spins = 0
        while stalls == 0 && spins < 1000 {
            await Task.yield()
            stalls = await wedgedSender.backpressureStalls
            spins += 1
        }
        #expect(stalls >= 1)
        #expect(overflowSend.isCancelled == false)

        // Unwedging the reader releases the suspended send.
        let wedgedReceiver = await hostEnd.lane("wedged")
        let drained = await wedgedReceiver.receive()
        #expect(drained != nil)
        try await overflowSend.value

        // The connection was never closed by backpressure (5.3).
        #expect(await client.isClosed == false)
    }

    @Test("for await consumption reads ordered frames until close")
    func forAwaitReadsUntilClose() async throws {
        let (client, hostEnd) = LoopbackWire().makeEnds()
        let sender = await client.lane("d")
        let receiver = await hostEnd.lane("d")
        for seq in Int64(0)..<10 {
            try await sender.send(TerminalTraffic.chunk(seq: seq, size: 16, seed: 5))
        }
        await client.closeAll()

        var validator = TrafficValidator()
        for await frame in receiver.frames {
            validator.ingest(frame)
        }
        #expect(validator.received == 10)
        #expect(validator.isClean)
    }

    @Test("A cancelled reader unparks with nil instead of leaking")
    func cancelledReaderUnparks() async throws {
        let (client, _) = LoopbackWire().makeEnds()
        let lane = await client.lane("idle")
        let reader = Task { await lane.receive() }
        for _ in 0..<50 { await Task.yield() }
        reader.cancel()
        // Before cancellation-aware receive, this awaited forever.
        #expect(await reader.value == nil)
    }

    @Test("A sender parked on backpressure observes cancellation as CancellationError")
    func cancelledSenderThrows() async throws {
        let (client, hostEnd) = LoopbackWire(laneCapacity: 1).makeEnds()
        _ = await hostEnd.lane("x")  // reader exists but never reads
        let lane = await client.lane("x")
        try await lane.send(TerminalTraffic.chunk(seq: 0, size: 16, seed: 4))

        let sender = Task {
            try await lane.send(TerminalTraffic.chunk(seq: 1, size: 16, seed: 4))
        }
        var stalls = await lane.backpressureStalls
        var spins = 0
        while stalls == 0 && spins < 1000 {
            await Task.yield()
            stalls = await lane.backpressureStalls
            spins += 1
        }
        sender.cancel()
        await #expect(throws: CancellationError.self) { try await sender.value }
        // The lane itself is unharmed (5.3): cancellation is per-task.
        #expect(await client.isClosed == false)
    }

    @Test("Closing the connection ends every lane; in-flight bytes die with the session (5.4)")
    func closeEndsLanes() async throws {
        let (client, hostEnd) = LoopbackWire().makeEnds()
        let sender = await client.lane("data")
        let receiver = await hostEnd.lane("data")
        try await sender.send(TerminalTraffic.chunk(seq: 0, size: 32, seed: 3))
        await client.closeAll()

        // Buffered frame drains, then EOF: nil, not a hang.
        #expect(await receiver.receive() != nil)
        #expect(await receiver.receive() == nil)

        // Sending into a dead session fails fast (7.2), never queues offline.
        await #expect(throws: TransportError.pipeClosed) {
            try await sender.send(TerminalTraffic.chunk(seq: 1, size: 32, seed: 3))
        }
    }
}
