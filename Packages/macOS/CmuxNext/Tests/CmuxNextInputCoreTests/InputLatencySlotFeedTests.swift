import CmuxNextInputCore
import Testing

/// The closed-slot feed behind the latency HUD's input rows (p04-input-009): a new reader gets the
/// newest slots oldest first, then each slot as it is published; a reader that falls behind loses
/// the oldest slots, counted, and never holds the publisher; a cancelled reader is forgotten. Run:
/// `swift test --filter InputLatencySlotFeedTests`.
@MainActor
struct InputLatencySlotFeedTests {
    private static func slot(_ generated: UInt64) -> InputLatencySlot {
        var slot = InputLatencySlot(kind: .keyPress, target: .terminal, entrypoint: .person, causedFrameUpdate: true)
        slot.generated = generated
        return slot
    }

    private static func next(_ iterator: inout AsyncStream<InputLatencySlot>.Iterator, _ count: Int) async -> [UInt64] {
        var generated: [UInt64] = []
        for _ in 0..<count {
            guard let slot = await iterator.next() else { break }
            generated.append(slot.generated)
        }
        return generated
    }

    @Test func aNewReaderGetsTheNewestSlotsThenEachNewOne() async {
        let feed = InputLatencySlotFeed()
        for generated in 1...20 { feed.publish(Self.slot(UInt64(generated))) }

        var all = feed.closedSlots(replaying: InputLatencySlotFeed.defaultKept).makeAsyncIterator()
        let replay = await Self.next(&all, 16)
        #expect(replay == Array(UInt64(5)...20), "the newest 16, oldest first")
        feed.publish(Self.slot(21))
        let live = await Self.next(&all, 1)
        #expect(live == [21])

        var few = feed.closedSlots(replaying: 3).makeAsyncIterator()
        let replayedFew = await Self.next(&few, 3)
        #expect(replayedFew == [19, 20, 21])
        #expect(feed.recentSlots(100).count == InputLatencySlotFeed.defaultKept, "never more than it keeps")
        #expect(InputLatencySlotFeed().recentSlots(4).isEmpty)
    }

    @Test func aSlowReaderLosesTheOldestSlotsAndIsCounted() async {
        let feed = InputLatencySlotFeed(keeping: 2)
        var reader = feed.closedSlots(replaying: 0).makeAsyncIterator()
        for generated in 1...5 { feed.publish(Self.slot(UInt64(generated))) }
        #expect(feed.droppedCount == 3)
        let kept = await Self.next(&reader, 2)
        #expect(kept == [4, 5])
        #expect(feed.publishedCount == 5)
    }

    @Test func aCancelledReaderEndsAndIsForgotten() async {
        let feed = InputLatencySlotFeed()
        feed.publish(Self.slot(1))
        let slots = feed.closedSlots(replaying: 1)
        #expect(feed.readerCount == 1)
        let reader = Task {
            var seen = 0
            for await _ in slots { seen += 1 }
            return seen
        }
        reader.cancel()
        _ = await reader.value  // the stream ended: the loop returned
        feed.publish(Self.slot(2))
        #expect(feed.readerCount == 0, "a publish after the end still yields to the reader")
    }
}
