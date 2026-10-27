import CmuxNextCompat
import CmuxNextWakeups
import Testing

/// ``FrameOutbox`` (p05-ipc-109): items offered on any thread reach the main actor in one batch per
/// flush, a flood asks for one flush, and past its limit the flush is a gap.
@Suite struct FrameOutboxTests {
    /// The flushes an outbox asked for; the test runs them as frames.
    final class Wakes: Sendable {
        private let flushes = Mutex<[FrameOutboxWake.Flush]>([])

        var wake: FrameOutboxWake {
            FrameOutboxWake { [self] flush in flushes.withLock { $0.append(flush) } }
        }

        /// Runs every flush asked for so far, as one frame; returns how many ran.
        @MainActor @discardableResult
        func frame() -> Int {
            let due = flushes.withLock { flushes -> [FrameOutboxWake.Flush] in
                defer { flushes = [] }
                return flushes
            }
            for flush in due { flush() }
            return due.count
        }
    }

    /// What the outbox delivered, one entry per flush.
    @MainActor final class Delivered {
        var batches: [(items: [Int], gap: Bool)] = []
    }

    @MainActor static func outbox(limit: Int, _ wakes: Wakes, _ delivered: Delivered) -> FrameOutbox<Int> {
        FrameOutbox<Int>(limit: limit, wake: wakes.wake) { items, gap in delivered.batches.append((items: items, gap: gap)) }
    }

    /// 1,000 offers from many threads at once ask for one flush, which hands over all of them.
    @MainActor @Test func aFloodFromManyThreadsAsksForOneFlush() async {
        let wakes = Wakes(), delivered = Delivered()
        let outbox = Self.outbox(limit: 2_000, wakes, delivered)
        await withTaskGroup(of: Void.self) { group in
            for item in 0..<1_000 { group.addTask { outbox.offer(item) } }
        }
        #expect(outbox.wakeCount == 1)
        #expect(wakes.frame() == 1)
        #expect(delivered.batches.count == 1)
        #expect(Set(delivered.batches.first?.items ?? []) == Set(0..<1_000))
        #expect(delivered.batches.first?.gap == false)

        outbox.offer(1_000)
        #expect(outbox.wakeCount == 2, "the first offer after a flush asks again")
        #expect(wakes.frame() == 1)
        #expect(delivered.batches.last?.items == [1_000])
    }

    /// Items offered in a row arrive in their order.
    @MainActor @Test func oneThreadsItemsKeepTheirOrder() {
        let wakes = Wakes(), delivered = Delivered()
        let outbox = Self.outbox(limit: 16, wakes, delivered)
        for item in 0..<10 { outbox.offer(item) }
        wakes.frame()
        #expect(delivered.batches.first?.items == Array(0..<10))
    }

    /// Past the limit the outbox drops what it holds and everything until the flush, which is one gap.
    @MainActor @Test func pastTheLimitTheFlushIsAGap() {
        let wakes = Wakes(), delivered = Delivered()
        let outbox = Self.outbox(limit: 256, wakes, delivered)
        for item in 0..<1_000 { outbox.offer(item) }
        #expect(outbox.wakeCount == 1)
        #expect(outbox.heldCount == 0, "a gap holds nothing")
        wakes.frame()
        #expect(delivered.batches.count == 1)
        #expect(delivered.batches.first?.items.isEmpty == true)
        #expect(delivered.batches.first?.gap == true)

        outbox.offer(7)
        wakes.frame()
        #expect(delivered.batches.last?.items == [7])
        #expect(delivered.batches.last?.gap == false, "the gap ended with its flush")
    }

    /// A gap the source reports drops what is held and what comes before the flush.
    @MainActor @Test func aReportedGapDropsWhatIsHeld() {
        let wakes = Wakes(), delivered = Delivered()
        let outbox = Self.outbox(limit: 16, wakes, delivered)
        outbox.offer(1)
        outbox.offer(2)
        outbox.offerGap()
        outbox.offer(3)
        #expect(outbox.wakeCount == 1)
        wakes.frame()
        #expect(delivered.batches.count == 1)
        #expect(delivered.batches.first?.items.isEmpty == true)
        #expect(delivered.batches.first?.gap == true)
    }

    /// A flush with nothing held delivers nothing.
    @MainActor @Test func anEmptyFlushDeliversNothing() {
        let wakes = Wakes(), delivered = Delivered()
        let outbox = Self.outbox(limit: 4, wakes, delivered)
        outbox.flush()
        #expect(delivered.batches.isEmpty)
        #expect(outbox.wakeCount == 0)
    }
}
