import CmuxNextLaunch
import CmuxNextWakeups
import Testing

/// #17587 review: the first window frame's waiting work (the non-paint services, each deferred
/// agent chat's web view, the later tabs' warm-ups) ran in one main-thread turn, inside the first
/// window's CATransaction completion, so the frame after the first stalled for all of it (3 agent
/// views, about 150 ms for the first, plus the services and warm-ups). Each waiter is its own step
/// now: input and a frame commit go between two of them.
@MainActor @Suite struct FirstFrameGateStepTests {
    /// Steps the test runs by hand.
    @MainActor final class Steps {
        var pending: [@MainActor @Sendable () -> Void] = []
        func step(_ next: @escaping @MainActor @Sendable () -> Void) { pending.append(next) }
        /// Runs the steps scheduled so far; returns how many.
        @discardableResult func fire() -> Int {
            let now = pending
            pending.removeAll()
            for next in now { next() }
            return now.count
        }
    }

    @Test func eachWaiterRunsInItsOwnStepInOrder() {
        let steps = Steps()
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()), step: steps.step)
        var ran: [String] = []
        gate.whenOpen { ran.append("services") }
        gate.whenOpen { ran.append("chat 1") }
        gate.whenOpen { ran.append("chat 2") }
        gate.open()
        #expect(ran.isEmpty, "the first frame's completion turn runs none of the work")
        steps.fire()
        #expect(ran == ["services"], "one waiter per step")
        steps.fire()
        #expect(ran == ["services", "chat 1"])
        steps.fire()
        #expect(ran == ["services", "chat 1", "chat 2"])
        #expect(steps.fire() == 0, "no step once the waiters ran")
    }

    @Test func workAddedWhileTheWaitersRunGoesAfterThem() {
        let steps = Steps()
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()), step: steps.step)
        var ran: [String] = []
        gate.whenOpen { ran.append("first") }
        gate.whenOpen { ran.append("second") }
        gate.open()
        steps.fire()
        gate.whenOpen { ran.append("late") }
        #expect(ran == ["first"], "work added while waiters remain keeps the order")
        while steps.fire() > 0 {}
        #expect(ran == ["first", "second", "late"])
        gate.whenOpen { ran.append("after") }
        #expect(ran.last == "after", "once every waiter ran, new work runs at once")
    }
}
