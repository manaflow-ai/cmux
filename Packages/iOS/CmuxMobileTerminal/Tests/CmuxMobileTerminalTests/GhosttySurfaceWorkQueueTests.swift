import Foundation
import Testing
import os

@testable import CmuxMobileTerminal

@Test("scroll priority runs ahead of queued repaint work")
func scrollPriorityRunsAheadOfQueuedRepaintWork() {
    let workQueue = GhosttySurfaceWorkQueue(generation: 1)
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let order = OSAllocatedUnfairLock<[String]>(initialState: [])

    workQueue.async {
        firstStarted.signal()
        releaseFirst.wait()
        order.withLock { $0.append("first") }
        completed.signal()
    }
    #expect(firstStarted.wait(timeout: .now() + 1) == .success)

    workQueue.async {
        order.withLock { $0.append("repaint") }
        completed.signal()
    }
    workQueue.asyncPriority {
        order.withLock { $0.append("scroll") }
        completed.signal()
    }
    releaseFirst.signal()

    #expect(completed.wait(timeout: .now() + 1) == .success)
    #expect(completed.wait(timeout: .now() + 1) == .success)
    #expect(completed.wait(timeout: .now() + 1) == .success)
    let observedOrder = order.withLock { $0 }
    #expect(observedOrder == ["first", "scroll", "repaint"])
}

@Test("normal work is serviced during sustained scroll priority")
func normalWorkIsServicedDuringSustainedScrollPriority() {
    let workQueue = GhosttySurfaceWorkQueue(generation: 2)
    let completed = DispatchSemaphore(value: 0)
    let order = OSAllocatedUnfairLock<[String]>(initialState: [])
    for index in 0..<5 {
        workQueue.asyncPriority {
            order.withLock { $0.append("scroll-\(index)") }
            completed.signal()
        }
    }
    workQueue.async {
        order.withLock { $0.append("repaint") }
        completed.signal()
    }
    for _ in 0..<6 {
        #expect(completed.wait(timeout: .now() + 1) == .success)
    }
    let observedOrder = order.withLock { $0 }
    #expect(observedOrder[4] == "repaint")
}

@Test("a new interaction starts with scroll priority after idle")
func newInteractionStartsWithScrollPriorityAfterIdle() {
    let workQueue = GhosttySurfaceWorkQueue(generation: 3)
    let completed = DispatchSemaphore(value: 0)
    let order = OSAllocatedUnfairLock<[String]>(initialState: [])
    for _ in 0..<4 {
        workQueue.asyncPriority {
            order.withLock { $0.append("scroll") }; completed.signal()
        }
    }
    for _ in 0..<4 { #expect(completed.wait(timeout: .now() + 1) == .success) }
    workQueue.async {
        order.withLock { $0.append("repaint") }; completed.signal()
    }
    workQueue.asyncPriority {
        order.withLock { $0.append("new-scroll") }; completed.signal()
    }
    #expect(completed.wait(timeout: .now() + 1) == .success)
    #expect(completed.wait(timeout: .now() + 1) == .success)
    let observedOrder = order.withLock { $0 }
    #expect(observedOrder.suffix(2).first == "new-scroll")
}
