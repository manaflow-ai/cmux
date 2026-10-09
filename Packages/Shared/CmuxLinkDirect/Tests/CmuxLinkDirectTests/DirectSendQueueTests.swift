import CmuxLink
@testable import CmuxLinkDirect
import Foundation
import Testing

@Suite("Direct send scheduling")
struct DirectSendQueueTests {
    @Test("interactive priorities overtake queued bulk while equal priority stays FIFO")
    func priorityAndFIFO() {
        var queue = DirectSendQueue(maxQueuedBulkBytes: 64)
        let bulk = TransportFrame(lane: TransportLane(reliability: .reliableOrdered, priority: .bulk), bytes: Data(repeating: 1, count: 16))
        let render = TransportFrame(lane: TransportLane(reliability: .reliableOrdered, priority: .render), bytes: Data(repeating: 2, count: 1))
        let firstInput = TransportFrame(lane: .control, bytes: Data([3]))
        let secondInput = TransportFrame(lane: .control, bytes: Data([4]))
        let now = ContinuousClock.now

        queue.enqueue(.init(id: 1, frame: bulk, queuedAt: now))
        queue.enqueue(.init(id: 2, frame: render, queuedAt: now))
        queue.enqueue(.init(id: 3, frame: firstInput, queuedAt: now))
        queue.enqueue(.init(id: 4, frame: secondInput, queuedAt: now))

        #expect(queue.dequeue()?.id == 3)
        #expect(queue.dequeue()?.id == 4)
        #expect(queue.dequeue()?.id == 2)
        #expect(queue.dequeue()?.id == 1)
    }

    @Test("queued bulk bytes are bounded and released when dequeued")
    func bulkBudget() {
        var queue = DirectSendQueue(maxQueuedBulkBytes: 16)
        let lane = TransportLane(reliability: .reliableOrdered, priority: .bulk)
        let first = TransportFrame(lane: lane, bytes: Data(repeating: 1, count: 12))
        let second = TransportFrame(lane: lane, bytes: Data(repeating: 2, count: 8))

        #expect(queue.canEnqueue(first))
        queue.enqueue(.init(id: 1, frame: first, queuedAt: .now))
        #expect(queue.queuedBulkBytes == 12)
        #expect(!queue.canEnqueue(second))
        #expect(queue.dequeue()?.id == 1)
        #expect(queue.queuedBulkBytes == 0)
        #expect(queue.canEnqueue(second))
    }
}
