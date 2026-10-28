import CmuxNextInputCore
import Testing

/// The closed-slot feed behind the latency HUD's input rows: a new reader hears the
/// newest slots oldest first before `addReader` returns, then each slot in the turn it is
/// published; a removed reader hears nothing more and is forgotten. Run:
/// `swift test --filter InputLatencySlotFeedTests`.
@MainActor
struct InputLatencySlotFeedTests {
    private final class Heard {
        var generated: [UInt64] = []
        var reader: InputLatencyReader?
    }

    private static func slot(_ generated: UInt64) -> InputLatencySlot {
        var slot = InputLatencySlot(kind: .keyPress, target: .terminal, entrypoint: .person, causedFrameUpdate: true)
        slot.generated = generated
        return slot
    }

    @Test func aNewReaderHearsTheNewestSlotsThenEachNewOne() {
        let feed = InputLatencySlotFeed()
        for generated in 1...20 { feed.publish(Self.slot(UInt64(generated))) }

        let all = Heard()
        let reader = feed.addReader(replaying: InputLatencySlotFeed.defaultKept) { all.generated.append($0.generated) }
        #expect(all.generated == Array(UInt64(5)...20), "the newest 16, oldest first, before addReader returns")
        feed.publish(Self.slot(21))
        #expect(all.generated.last == 21, "a published slot reaches the reader in the same turn")

        let few = Heard()
        let fewReader = feed.addReader(replaying: 3) { few.generated.append($0.generated) }
        #expect(few.generated == [19, 20, 21])
        #expect(feed.recentSlots(100).count == InputLatencySlotFeed.defaultKept, "never more than it keeps")
        #expect(InputLatencySlotFeed().recentSlots(4).isEmpty)
        feed.removeReader(reader)
        feed.removeReader(fewReader)
    }

    @Test func aRemovedReaderHearsNothingMoreAndIsForgotten() {
        let feed = InputLatencySlotFeed()
        feed.publish(Self.slot(1))
        let heard = Heard()
        let reader = feed.addReader(replaying: 1) { heard.generated.append($0.generated) }
        #expect(feed.readerCount == 1)
        feed.removeReader(reader)
        feed.removeReader(reader)  // twice is harmless
        feed.publish(Self.slot(2))
        #expect(heard.generated == [1])
        #expect(feed.readerCount == 0)
        #expect(feed.publishedCount == 2)
    }

    @Test func aReaderMayRemoveItselfWhileItReads() {
        let feed = InputLatencySlotFeed()
        let heard = Heard()
        heard.reader = feed.addReader(replaying: 0) { slot in
            heard.generated.append(slot.generated)
            if let reader = heard.reader { feed.removeReader(reader) }
        }
        feed.publish(Self.slot(1))
        feed.publish(Self.slot(2))
        #expect(heard.generated == [1])
        #expect(feed.readerCount == 0)
    }
}
