import CmuxNextControl
import CmuxNextInputCore
import Testing

/// The off-main half of input latency (p04-input-002): batches handed over without waiting are
/// folded on the reporter's reader, a snapshot sees every accepted batch, and a batch a full
/// stream pushes out (or one sent after the end) counts as dropped.
@Suite struct InputLatencyReporterTests {
    private static let ms: UInt64 = 1_000_000

    private static func batch(_ count: Int, droppedTotal: UInt64 = 0) -> InputLatencyBatch {
        let slots = (0..<count).map { index -> InputLatencySlot in
            var slot = InputLatencySlot(kind: .keyPress, target: .terminal, entrypoint: .person, causedFrameUpdate: true)
            slot.generated = UInt64(index + 1) * ms
            slot.presented = UInt64(index + 1) * ms + 6 * ms
            return slot
        }
        return InputLatencyBatch(slots: slots, vsyncNanos: 16_666_667, droppedTotal: droppedTotal)
    }

    @Test func aSnapshotSeesEveryAcceptedBatch() async {
        let reporter = InputLatencyReporter()
        let reader = Task.detached(priority: .utility) { await reporter.run() }
        reporter.submit(Self.batch(3, droppedTotal: 1))
        reporter.submit(Self.batch(2, droppedTotal: 1))
        let snapshot = await reporter.snapshot()
        #expect(snapshot.slotsReceived == 5)
        #expect(snapshot.slotsDropped == 1)
        #expect(snapshot.rows.first?.count == 5)
        #expect(snapshot.rows.first?.total.maxMilliseconds == 6)
        reporter.finish()
        await reader.value
    }

    @Test func aBatchAFullStreamPushesOutIsCountedAsDropped() async {
        // No reader yet: the one-batch buffer keeps the newest batch and drops the older one.
        let reporter = InputLatencyReporter(bufferedBatches: 1)
        reporter.submit(Self.batch(4, droppedTotal: 2))
        reporter.submit(Self.batch(3, droppedTotal: 2))
        reporter.finish()
        reporter.submit(Self.batch(5))
        await reporter.run()
        let snapshot = await reporter.snapshot()
        #expect(snapshot.slotsReceived == 3, "only the newest batch reached the ledger")
        #expect(snapshot.slotsDropped == 4 + 2 + 5, "the pushed-out batch, the producer drops the kept batch carries, and the batch after the end")
    }
}
