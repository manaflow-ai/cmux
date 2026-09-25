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
}
