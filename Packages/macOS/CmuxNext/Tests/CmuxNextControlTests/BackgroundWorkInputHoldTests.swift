import CmuxNextWakeups
import Dispatch
import Foundation
import os
import Testing

/// Leo: "isn't there a thing where we can dynamically adjust priorities of things based off of how interactive
/// they are?" While the person drags, types or scrolls, BackgroundWork holds best-effort and idle work (saves,
/// prefetch, indexing) back, at most a second, and work a person sees or waits for still starts at once.
@Suite(.timeLimit(.minutes(1))) struct BackgroundWorkInputHoldTests {
    @Test(arguments: BlockingLane.allCases)
    func lowWorkWaitsForInputToStopAndVisibleWorkDoesNot(lane: BlockingLane) async throws {
        let input = OSAllocatedUnfairLock(initialState: true)
        let work = BackgroundWork(cpuWidth: 2, label: "test.hold", interacting: { input.withLock { $0 } })
        let ran = OSAllocatedUnfairLock<[WorkPriority]>(initialState: [])
        for priority in [WorkPriority.idle, .bestEffort] {
            work.post(priority, mayBlock: lane) { ran.withLock { $0.append(priority) } }
        }
        // Visible work starts during the drag, and it finishing does not let the held work through.
        try await Task(priority: .utility) {
            try await work.run(.userVisible, mayBlock: lane) { ran.withLock { $0.append(.userVisible) } }
        }.value
        try await Task.sleep(for: .milliseconds(250))
        #expect(ran.withLock { $0 } == [.userVisible])

        input.withLock { $0 = false }
        let deadline = ContinuousClock.now + .seconds(2)
        while ran.withLock({ $0.count }) < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Set(ran.withLock { $0 }) == [.userVisible, .bestEffort, .idle])
    }

    @Test func aHeldItemStartsAfterTheMaximumHoldEvenWhileInputGoesOn() async throws {
        let work = BackgroundWork(label: "test.hold.cap", interacting: { true })
        let started = ContinuousClock.now
        let (done, finish) = AsyncStream.makeStream(of: Duration.self)
        work.post(.bestEffort, mayBlock: .files) { finish.yield(ContinuousClock.now - started) }
        var iterator = done.makeAsyncIterator()
        let waited = try #require(await iterator.next())
        #expect(waited >= .milliseconds(900), "held only \(waited)")
        #expect(waited < .seconds(3), "held \(waited)")
    }

    @Test func anAwaitedItemRunsAtItsCallersPriorityAndIsNotHeld() async throws {
        let work = BackgroundWork(label: "test.hold.await", interacting: { true })
        let started = ContinuousClock.now
        // A UI path that awaits best-effort work boosts it to its own priority, which is never held.
        try await Task(priority: .high) { try await work.run(.bestEffort, mayBlock: .files) {} }.value
        #expect(ContinuousClock.now - started < .milliseconds(500))
    }
}
