import Foundation
import Testing
@testable import CmuxMobileHost

@Suite("Mobile host event queue")
struct MobileHostConnectionEventQueueTests {
    @Test("Mac grid replacement moves to the back and keeps latest dimensions")
    func replacementMovesToBack() {
        let queue = MobileHostConnectionEventQueue(maximumEventCount: 3, maximumByteCount: 32)
        queue.updateSubscribedTopics(["device.terminal.grid", "terminal.bytes"])
        #expect(queue.enqueue(topic: "device.terminal.grid", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([1])).admitted)
        #expect(queue.enqueue(topic: "terminal.bytes", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([2])).admitted)
        #expect(queue.enqueue(topic: "device.terminal.grid", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([3])).admitted)
        #expect(queue.dequeue()?.frame == Data([2]))
        #expect(queue.dequeue()?.frame == Data([3]))
    }

    @Test("Distinct Mac grids return overflow without growing the mailbox")
    func distinctGridOverflow() {
        let queue = MobileHostConnectionEventQueue(maximumEventCount: 1, maximumByteCount: 4)
        queue.updateSubscribedTopics(["device.terminal.grid"])
        #expect(queue.enqueue(topic: "device.terminal.grid", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([1])).admitted)
        let result = queue.enqueue(topic: "device.terminal.grid", coalesceKey: "b", isFullRenderGridFrame: false, frame: Data([2]))
        #expect(result.overflowed)
        #expect(!result.admitted)
        #expect(queue.count == 1)
        #expect(queue.consumeOverflow())
        #expect(!queue.consumeOverflow())
    }

    @Test("A replacement grid that cannot fit records overflow and claims the drain")
    func replacementOverflowClaimsDrain() {
        let queue = MobileHostConnectionEventQueue(maximumEventCount: 4, maximumByteCount: 4)
        queue.updateSubscribedTopics(["device.terminal.grid"])
        #expect(queue.enqueue(topic: "device.terminal.grid", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([1])).startDrain)
        #expect(queue.dequeue() != nil)
        #expect(!queue.finishDrain())
        #expect(queue.enqueue(topic: "device.terminal.grid", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([1])).startDrain)
        let result = queue.enqueue(topic: "device.terminal.grid", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data(count: 5))
        #expect(result.overflowed)
        #expect(!result.admitted)
        // The drain that the first enqueue claimed is still running, so this
        // overflow must reach it through the queue's pending flag.
        #expect(!result.startDrain)
        #expect(queue.consumeOverflow())
    }

    @Test("A growing replacement grid sheds droppable events before it overflows")
    func replacementShedsDroppableEventsBeforeOverflow() {
        let queue = MobileHostConnectionEventQueue(maximumEventCount: 4, maximumByteCount: 4)
        queue.updateSubscribedTopics(["device.terminal.grid", "terminal.bytes"])
        #expect(queue.enqueue(topic: "device.terminal.grid", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([1])).admitted)
        #expect(queue.enqueue(topic: "terminal.bytes", coalesceKey: nil, isFullRenderGridFrame: false, frame: Data([2, 3])).admitted)
        // The replacement needs 3 bytes where the old grid held 1; shedding the
        // terminal bytes makes room, so the connection must stay open.
        let result = queue.enqueue(topic: "device.terminal.grid", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data(count: 3))
        #expect(result.admitted)
        #expect(!result.overflowed)
        #expect(result.shedEventCount == 1)
        #expect(!queue.consumeOverflow())
        #expect(queue.dequeue()?.frame.count == 3)
        #expect(queue.dequeue() == nil)
    }

    @Test("A replacement overflow with no active drain starts one")
    func replacementOverflowStartsIdleDrain() {
        let queue = MobileHostConnectionEventQueue(maximumEventCount: 4, maximumByteCount: 4)
        queue.updateSubscribedTopics(["device.terminal.grid"])
        #expect(queue.enqueue(topic: "device.terminal.grid", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([1])).startDrain)
        queue.abandonDrain()
        let result = queue.enqueue(topic: "device.terminal.grid", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data(count: 5))
        #expect(result.overflowed)
        #expect(result.startDrain)
        #expect(queue.consumeOverflow())
    }

    @Test("A running drain cannot finish over a pending overflow")
    func finishDrainKeepsPendingOverflow() {
        let queue = MobileHostConnectionEventQueue(maximumEventCount: 1, maximumByteCount: 4)
        queue.updateSubscribedTopics(["device.terminal.grid"])
        #expect(queue.enqueue(topic: "device.terminal.grid", coalesceKey: "a", isFullRenderGridFrame: false, frame: Data([1])).startDrain)
        #expect(queue.enqueue(topic: "device.terminal.grid", coalesceKey: "b", isFullRenderGridFrame: false, frame: Data([2])).overflowed)
        #expect(queue.dequeue() != nil)
        #expect(queue.dequeue() == nil)
        // The queue is empty, but the drain owns the overflow it has not consumed yet.
        #expect(queue.finishDrain())
        #expect(queue.consumeOverflow())
        #expect(!queue.finishDrain())
    }
}
