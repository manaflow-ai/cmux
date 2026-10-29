import CmuxNextControl
import CmuxNextInputCore
import Testing

/// The off-main half of input latency: batches handed over without waiting are
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

    @Test func aResetStartsTheReportOverAndKeepsTheDropBaseline() async {
        let reporter = InputLatencyReporter()
        let reader = Task.detached(priority: .utility) { await reporter.run() }
        reporter.submit(Self.batch(3, droppedTotal: 2))
        await reporter.reset()
        let empty = await reporter.snapshot()
        #expect(empty.slotsReceived == 0, "the batch accepted before the reset was folded, then cleared")
        #expect(empty.slotsDropped == 0)
        #expect(empty.rows.isEmpty)
        reporter.submit(Self.batch(1, droppedTotal: 3))
        let after = await reporter.snapshot()
        #expect(after.slotsReceived == 1)
        #expect(after.slotsDropped == 1, "only the slot lost after the reset: the producer's total is cumulative")
        reporter.finish()
        await reader.value
    }

    @Test func theFieldReportCountsOnlyWhileOnAndACommittedTakeStartsOver() async {
        // The opt-in report's own ledger; debug.input's reset never changes it.
        let reporter = InputLatencyReporter()
        let reader = Task.detached(priority: .utility) { await reporter.run() }
        reporter.submit(Self.batch(2, droppedTotal: 1))
        #expect(await reporter.takeFieldReport() == nil, "off: no field ledger")
        #expect(await reporter.fieldReportPreview() == nil)
        await reporter.setFieldReport(true)
        reporter.submit(Self.batch(3, droppedTotal: 2))
        await reporter.reset()
        let preview = await reporter.fieldReportPreview()
        #expect(preview?.slotsReceived == 3, "the batch after the start, kept across the debug.input reset")
        let first = await reporter.takeFieldReport()
        #expect(first == preview, "the preview is what the next take returns")
        #expect(first?.slotsDropped == 1, "only the slot lost after the start")
        #expect(first?.rows.first?.count == 3)
        await reporter.commitFieldReport()
        let second = await reporter.takeFieldReport()
        #expect(second?.slotsReceived == 0, "a committed take starts the field report over")
        await reporter.setFieldReport(false)
        reporter.submit(Self.batch(1, droppedTotal: 2))
        #expect(await reporter.takeFieldReport() == nil)
        reporter.finish()
        await reader.value
    }

    @Test func aTakeNotCommittedComesBackWithTheNextOne() async {
        // A report dropped before it was queued (daily cap, leak scan, size) loses no input counts.
        let reporter = InputLatencyReporter()
        let reader = Task.detached(priority: .utility) { await reporter.run() }
        await reporter.setFieldReport(true)
        reporter.submit(Self.batch(2))
        #expect(await reporter.takeFieldReport()?.slotsReceived == 2)
        reporter.submit(Self.batch(3))
        #expect(await reporter.takeFieldReport()?.slotsReceived == 5, "the uncommitted counts and the new ones")
        await reporter.commitFieldReport()
        reporter.submit(Self.batch(1))
        #expect(await reporter.fieldReportPreview()?.slotsReceived == 1)
        // Off drops the taken counts too: nothing recorded before off goes out after on.
        #expect(await reporter.takeFieldReport()?.slotsReceived == 1)
        await reporter.setFieldReport(false)
        await reporter.setFieldReport(true)
        #expect(await reporter.takeFieldReport()?.slotsReceived == 0)
        reporter.finish()
        await reader.value
    }
}
