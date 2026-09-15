import Foundation
import Testing

@Test("scroll priority runs ahead of queued repaint work")
func scrollPriorityRunsAheadOfQueuedRepaintWork() {
    let workQueue = GhosttySurfaceWorkQueue(generation: 1)
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var order: [String] = []

    workQueue.async {
        firstStarted.signal()
        releaseFirst.wait()
        lock.lock()
        order.append("first")
        lock.unlock()
        completed.signal()
    }
    #expect(firstStarted.wait(timeout: .now() + 1) == .success)

    workQueue.async {
        lock.lock()
        order.append("repaint")
        lock.unlock()
        completed.signal()
    }
    workQueue.asyncPriority {
        lock.lock()
        order.append("scroll")
        lock.unlock()
        completed.signal()
    }
    releaseFirst.signal()

    #expect(completed.wait(timeout: .now() + 1) == .success)
    #expect(completed.wait(timeout: .now() + 1) == .success)
    #expect(completed.wait(timeout: .now() + 1) == .success)
    lock.lock()
    let observedOrder = order
    lock.unlock()
    #expect(observedOrder == ["first", "scroll", "repaint"])
}

@Test("normal work is serviced during sustained scroll priority")
func normalWorkIsServicedDuringSustainedScrollPriority() {
    let workQueue = GhosttySurfaceWorkQueue(generation: 2)
    let completed = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var order: [String] = []
    for index in 0..<5 {
        workQueue.asyncPriority {
            lock.lock()
            order.append("scroll-\(index)")
            lock.unlock()
            completed.signal()
        }
    }
    workQueue.async {
        lock.lock()
        order.append("repaint")
        lock.unlock()
        completed.signal()
    }
    for _ in 0..<6 {
        #expect(completed.wait(timeout: .now() + 1) == .success)
    }
    lock.lock()
    let observedOrder = order
    lock.unlock()
    #expect(observedOrder[4] == "repaint")
}

@Test("a new interaction starts with scroll priority after idle")
func newInteractionStartsWithScrollPriorityAfterIdle() {
    let workQueue = GhosttySurfaceWorkQueue(generation: 3)
    let completed = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var order: [String] = []
    for _ in 0..<4 {
        workQueue.asyncPriority {
            lock.lock(); order.append("scroll"); lock.unlock(); completed.signal()
        }
    }
    for _ in 0..<4 { #expect(completed.wait(timeout: .now() + 1) == .success) }
    workQueue.async {
        lock.lock(); order.append("repaint"); lock.unlock(); completed.signal()
    }
    workQueue.asyncPriority {
        lock.lock(); order.append("new-scroll"); lock.unlock(); completed.signal()
    }
    #expect(completed.wait(timeout: .now() + 1) == .success)
    #expect(completed.wait(timeout: .now() + 1) == .success)
    lock.lock(); let observedOrder = order; lock.unlock()
    #expect(observedOrder.suffix(2).first == "new-scroll")
}
