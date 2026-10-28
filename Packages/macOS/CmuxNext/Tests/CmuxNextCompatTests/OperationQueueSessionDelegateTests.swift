import CmuxNextCompat
import Foundation
import Testing

/// A URLSession's delegate queue has the name and QoS it was given and runs one operation at a
/// time, as the unnamed serial queue a nil `delegateQueue:` makes, so delegate calls keep their order.
struct OperationQueueSessionDelegateTests {
    @Test func theQueueHasItsNameItsQoSAndRunsOneOperationAtATime() {
        let queue = OperationQueue.sessionDelegate("com.cmuxterm.next.test.session-delegate", qos: .utility)
        #expect(queue.name == "com.cmuxterm.next.test.session-delegate")
        #expect(queue.qualityOfService == .utility)
        #expect(queue.maxConcurrentOperationCount == 1)
    }

    @Test func eachQueueIsItsOwn() {
        let first = OperationQueue.sessionDelegate("com.cmuxterm.next.test.a", qos: .userInitiated)
        let second = OperationQueue.sessionDelegate("com.cmuxterm.next.test.b", qos: .userInitiated)
        #expect(first !== second)
        #expect(first.qualityOfService == .userInitiated)
    }
}
