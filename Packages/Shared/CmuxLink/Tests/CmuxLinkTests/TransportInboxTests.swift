import CmuxLink
import Foundation
import os
import Testing

@Suite("TransportInbox")
struct TransportInboxTests {
    static let reliable = TransportLane(reliability: .reliableOrdered, priority: .bulk)
    static let unordered = TransportLane(reliability: .unreliableUnordered, priority: .media)

    static func frame(_ lane: TransportLane, _ size: Int, tag: UInt8 = 0) -> TransportEvent {
        .frame(TransportFrame(lane: lane, bytes: Data(repeating: tag, count: size)))
    }

    @Test func unreliableFloodWithoutConsumerStaysBoundedAndCountsDrops() {
        let inbox = TransportInbox(limits: .init(unreliableBytes: 64 << 10))
        var dropped = 0
        for _ in 0..<1000 where inbox.yield(Self.frame(Self.unordered, 1200)) == .dropped { dropped += 1 }
        let stats = inbox.stats
        #expect(stats.queuedUnreliableBytes <= 64 << 10)
        #expect(stats.droppedFrames == dropped)
        #expect(dropped > 900)
        #expect(stats.droppedBytes == dropped * 1200)
    }

    @Test func reliableIngressWaitsForRoomAndOverflowIsRefused() async {
        let inbox = TransportInbox(limits: .init(reliableBytes: 4096, reliableOverflowBytes: 8192))
        #expect(inbox.yield(Self.frame(Self.reliable, 4096)) == .accepted)
        #expect(!inbox.hasRoom)
        #expect(inbox.yield(Self.frame(Self.reliable, 4096)) == .accepted)
        #expect(inbox.yield(Self.frame(Self.reliable, 1)) == .overflow)
        let resumed = Task { await inbox.waitForRoom() }
        _ = await inbox.next()
        #expect(!inbox.hasRoom)
        _ = await inbox.next()
        await resumed.value
        #expect(inbox.hasRoom)
        #expect(inbox.stats.peakReliableBytes == 8192)
    }

    @Test func creditFiresOnConsumptionNotArrival() async {
        let inbox = TransportInbox()
        let credited = OSAllocatedUnfairLock(initialState: 0)
        inbox.setConsumeHandler { _, cost in credited.withLock { $0 += cost } }
        inbox.yield(Self.frame(Self.reliable, 100), cost: 101)
        inbox.yield(Self.frame(Self.reliable, 50))
        #expect(credited.withLock { $0 } == 0)
        _ = await inbox.next()
        #expect(credited.withLock { $0 } == 101)
        _ = await inbox.next()
        #expect(credited.withLock { $0 } == 151)
    }

    @Test func closedComesAfterQueuedFramesAndEndsTheInbox() async {
        let inbox = TransportInbox()
        inbox.yield(Self.frame(Self.reliable, 10, tag: 1))
        inbox.yield(.rtt(.milliseconds(5)))
        inbox.yield(.rtt(.milliseconds(9)))
        inbox.yield(.closed(.remote))
        #expect(inbox.yield(Self.frame(Self.reliable, 10)) == .finished)
        var seen: [String] = []
        for await event in inbox.events {
            switch event {
            case .frame: seen.append("frame")
            case let .rtt(rtt): seen.append("rtt \(rtt)")
            case .closed: seen.append("closed")
            default: seen.append("other")
            }
        }
        #expect(seen == ["frame", "rtt 0.009 seconds", "closed"])
    }

    @Test func cancellingAWaitingConsumerEndsItsRead() async {
        let inbox = TransportInbox()
        let reader = Task { await inbox.next() }
        reader.cancel()
        #expect(await reader.value == nil)
    }

    @Test func aWaitingConsumerGetsTheNextFrameDirectly() async {
        let inbox = TransportInbox()
        let reader = Task { await inbox.next() }
        await Task.yield()
        inbox.yield(Self.frame(Self.reliable, 3, tag: 7))
        guard case let .frame(frame)? = await reader.value else {
            Issue.record("no frame")
            return
        }
        #expect(frame.bytes == Data([7, 7, 7]))
        #expect(inbox.stats.queuedReliableBytes == 0)
    }
}
