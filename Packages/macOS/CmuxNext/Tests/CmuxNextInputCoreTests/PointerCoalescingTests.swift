import CmuxNextInputCore
import Testing

/// The merge rules of continuous pointer input (Chromium's WebCoalescedInputEvent
/// CanCoalesceWith and CoalesceWith): moves keep the latest, drags keep the latest and the newest 16
/// points, scrolls sum within one phase, a merged delivery keeps the oldest time and a count, and the
/// queue merges only into its newest entry so order holds.
struct PointerCoalescingTests {
    @Test func movesKeepTheLatestTheOldestTimeAndTheCount() throws {
        var input = try #require(PointerCoalescedInput(Self.record(.mouseMoved, x: 1, at: 10)))
        let merged1 = input.merge(Self.record(.mouseMoved, x: 2, at: 11))
        #expect(merged1)
        let merged2 = input.merge(Self.record(.mouseMoved, x: 3, at: 12))
        #expect(merged2)
        #expect(input.kind == .move)
        #expect(input.latest.location == InputPoint(x: 3, y: 0))
        #expect(input.oldestTimestamp == 10)
        #expect(input.coalescedCount == 3)
        #expect(input.samples.isEmpty, "a move keeps no history: the latest wins")
        #expect(input.scrollDelta == .zero)
    }

    @Test func dragsKeepTheNewestSixteenPointsOldestFirst() throws {
        var input = try #require(PointerCoalescedInput(Self.record(.leftMouseDragged, x: 0, at: 0)))
        for index in 1..<20 {
            let merged1 = input.merge(Self.record(.leftMouseDragged, x: Double(index), at: Double(index)))
            #expect(merged1)
        }
        #expect(input.coalescedCount == 20)
        #expect(input.oldestTimestamp == 0, "the oldest time survives the dropped samples")
        #expect(input.samples.count == PointerCoalescedInput.sampleCapacity)
        #expect(input.samples.map(\.location.x) == (4..<20).map { Double($0) })
        #expect(input.samples.last?.timestamp == 19)
        #expect(input.latest.location.x == 19)
    }

    @Test func scrollsSumWithinOnePhase() throws {
        var input = try #require(PointerCoalescedInput(Self.scroll(.changed, dy: 2, at: 1)))
        let merged1 = input.merge(Self.scroll(.changed, dy: 3, at: 2))
        #expect(merged1)
        let merged2 = input.merge(Self.scroll(.changed, dy: -1, at: 3))
        #expect(merged2)
        #expect(input.scrollDelta == InputPoint(x: 0, y: 4))
        #expect(input.coalescedCount == 3)
        #expect(input.oldestTimestamp == 1)
        let merged3 = input.merge(Self.scroll(.ended, dy: 0, at: 4))
        #expect(!merged3, "a phase change starts a new delivery")
        let merged4 = input.merge(Self.scroll(.momentum, dy: 5, at: 4))
        #expect(!merged4, "momentum is its own phase")
        let merged5 = input.merge(Self.scroll(.changed, dy: 1, at: 4, precise: false))
        #expect(!merged5, "line deltas do not add to points")
        #expect(input.scrollDelta == InputPoint(x: 0, y: 4), "a refused merge changes nothing")
    }

    @Test func eventsOfAnotherKindButtonModifierOrWindowDoNotMerge() throws {
        let drag = try #require(PointerCoalescedInput(Self.record(.leftMouseDragged, x: 0, at: 0)))
        #expect(!drag.canMerge(Self.record(.mouseMoved, x: 1, at: 1)))
        #expect(!drag.canMerge(Self.record(.rightMouseDragged, x: 1, at: 1)))
        #expect(!drag.canMerge(Self.record(.leftMouseDragged, x: 1, at: 1, modifiers: .shift)))
        #expect(!drag.canMerge(Self.record(.leftMouseDragged, x: 1, at: 1, window: 7)))
        #expect(drag.canMerge(Self.record(.leftMouseDragged, x: 1, at: 1)))
        #expect(PointerCoalescedInput(Self.record(.leftMouseDown, x: 0, at: 0)) == nil, "a button is discrete")
        #expect(PointerCoalescedInput(InputEventRecord(type: .keyDown, timestamp: 0)) == nil)
        #expect(PointerCoalescedInput(InputEventRecord(type: .magnify, timestamp: 0)) == nil)
    }

    /// The queue merges only into its newest entry (MainThreadEventQueue coalesces with the last
    /// event), so a move between two drags keeps three entries in order.
    @Test func theQueueMergesIntoItsNewestEntryOnlyAndKeepsOrder() {
        var queue = PointerCoalescingQueue()
        let queued1 = queue.append(Self.record(.leftMouseDragged, x: 1, at: 1))
        #expect(queued1)
        let queued2 = queue.append(Self.record(.leftMouseDragged, x: 2, at: 2))
        #expect(queued2)
        let queued3 = queue.append(Self.record(.mouseMoved, x: 3, at: 3))
        #expect(queued3)
        let queued4 = queue.append(Self.record(.leftMouseDragged, x: 4, at: 4))
        #expect(queued4)
        let queued5 = queue.append(Self.scroll(.began, dy: 1, at: 5))
        #expect(queued5)
        let queued6 = queue.append(Self.scroll(.changed, dy: 2, at: 6))
        #expect(queued6)
        let queued7 = queue.append(Self.scroll(.changed, dy: 3, at: 7))
        #expect(queued7)
        let queued8 = queue.append(Self.record(.leftMouseUp, x: 0, at: 8))
        #expect(!queued8, "discrete input is not queued")
        #expect(queue.hasDrag)
        var drained: [PointerCoalescedInput] = []
        queue.drain { drained.append($0) }
        #expect(drained.map(\.kind) == [.drag, .move, .drag, .scroll, .scroll])
        #expect(drained.map(\.coalescedCount) == [2, 1, 1, 1, 2])
        #expect(drained.last?.scrollDelta == InputPoint(x: 0, y: 5))
        #expect(drained.last?.oldestTimestamp == 6)
        #expect(queue.isEmpty)
        #expect(!queue.hasDrag)
    }

    /// A drained or delivered drag gives its sample storage back, and the next drag reuses it: a steady
    /// drag makes no buffer per frame. The pool is bounded.
    @Test func drainedDragSamplesAreReusedByTheNextDrag() throws {
        var queue = PointerCoalescingQueue()
        queue.append(Self.record(.leftMouseDragged, x: 1, at: 1))
        queue.append(Self.record(.mouseMoved, x: 2, at: 2))
        queue.drain { _ in }
        #expect(queue.spareSampleBuffers == 1, "a move has no samples to give back")
        // `single` is mutating; #require's expansion would call it on an immutable copy.
        let taken = queue.single(Self.record(.leftMouseDragged, x: 3, at: 3))
        var single = try #require(taken)
        #expect(queue.spareSampleBuffers == 0, "the next drag took the pooled buffer")
        #expect(single.samples.map(\.location.x) == [3], "a reused buffer starts empty")
        #expect(single.samples.capacity >= PointerCoalescedInput.sampleCapacity)
        queue.recycle(&single)
        #expect(queue.spareSampleBuffers == 1)
        for index in 0..<10 {
            var input = try #require(PointerCoalescedInput(Self.record(.leftMouseDragged, x: Double(index), at: 0)))
            queue.recycle(&input)
        }
        #expect(queue.spareSampleBuffers == PointerCoalescingQueue.spareSampleLimit)
    }

    // MARK: Support

    private static func record(_ type: InputEventType, x: Double, at time: Double, modifiers: InputModifierFlags = [],
                               window: Int = 1) -> InputEventRecord {
        InputEventRecord(type: type, timestamp: time, windowNumber: window, location: InputPoint(x: x, y: 0),
                         modifierFlags: modifiers)
    }

    private static func scroll(_ phase: InputScrollPhase, dy: Double, at time: Double, precise: Bool = true) -> InputEventRecord {
        InputEventRecord(type: .scrollWheel, timestamp: time, windowNumber: 1, scrollPhase: phase,
                         scrollDelta: InputPoint(x: 0, y: dy), hasPreciseScrollingDeltas: precise)
    }
}
