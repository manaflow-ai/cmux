import Foundation
import Testing

@testable import CmuxMobileTerminal

private final class RecordedWorkOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Test("scroll priority runs ahead of queued repaint work")
func scrollPriorityRunsAheadOfQueuedRepaintWork() {
    let workQueue = GhosttySurfaceWorkQueue(generation: 1)
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let order = RecordedWorkOrder()

    workQueue.async {
        firstStarted.signal()
        releaseFirst.wait()
        order.append("first")
        completed.signal()
    }
    #expect(firstStarted.wait(timeout: .now() + 1) == .success)

    workQueue.async {
        order.append("repaint")
        completed.signal()
    }
    workQueue.asyncPriority {
        order.append("scroll")
        completed.signal()
    }
    releaseFirst.signal()

    #expect(completed.wait(timeout: .now() + 1) == .success)
    #expect(completed.wait(timeout: .now() + 1) == .success)
    #expect(completed.wait(timeout: .now() + 1) == .success)
    let observedOrder = order.snapshot()
    #expect(observedOrder == ["first", "scroll", "repaint"])
}

@Test("normal work is serviced during sustained scroll priority")
func normalWorkIsServicedDuringSustainedScrollPriority() {
    let workQueue = GhosttySurfaceWorkQueue(generation: 2)
    let completed = DispatchSemaphore(value: 0)
    let order = RecordedWorkOrder()
    for index in 0..<5 {
        workQueue.asyncPriority {
            order.append("scroll-\(index)")
            completed.signal()
        }
    }
    workQueue.async {
        order.append("repaint")
        completed.signal()
    }
    for _ in 0..<6 {
        #expect(completed.wait(timeout: .now() + 1) == .success)
    }
    let observedOrder = order.snapshot()
    #expect(observedOrder[4] == "repaint")
}

@Test("a new interaction starts with scroll priority after idle")
func newInteractionStartsWithScrollPriorityAfterIdle() {
    let workQueue = GhosttySurfaceWorkQueue(generation: 3)
    let completed = DispatchSemaphore(value: 0)
    let order = RecordedWorkOrder()
    for _ in 0..<4 {
        workQueue.asyncPriority {
            order.append("scroll"); completed.signal()
        }
    }
    for _ in 0..<4 { #expect(completed.wait(timeout: .now() + 1) == .success) }
    workQueue.async {
        order.append("repaint"); completed.signal()
    }
    workQueue.asyncPriority {
        order.append("new-scroll"); completed.signal()
    }
    #expect(completed.wait(timeout: .now() + 1) == .success)
    #expect(completed.wait(timeout: .now() + 1) == .success)
    let observedOrder = order.snapshot()
    #expect(observedOrder.suffix(2).first == "new-scroll")
}

@Test("geometry mutation advances the generation even at unchanged dimensions")
func geometryMutationAdvancesGenerationAtUnchangedDimensions() {
    let workQueue = GhosttySurfaceWorkQueue(generation: 4)
    let initial = workQueue.noteObservedGrid(columns: 80, rows: 24)
    workQueue.gridGenerationAtLastRenderGridApply = initial

    workQueue.markGridMutation()

    #expect(workQueue.observedGridGeneration == initial + 1)
    #expect(workQueue.gridGenerationAtLastRenderGridApply != workQueue.observedGridGeneration)
}
