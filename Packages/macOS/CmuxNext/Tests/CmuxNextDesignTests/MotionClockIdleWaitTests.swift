import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// ``MotionClock/waitIdle()``: a continuation the clock resumes where its last animator leaves
/// (the frame it rests on, ``MotionClock/stop(_:)``), never a frame client or a poll; a cancelled wait resumes
/// false and leaves nothing behind. ``MotionClock/existing(in:)`` creates no clock.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MotionClockIdleWaitTests {
    @MainActor final class Spring: MotionAnimating {
        var steps = 0
        let restAfter: Int
        init(restAfter: Int) { self.restAfter = restAfter }
        func motionStep(_ tick: FrameTick) -> Bool {
            steps += 1
            return steps < restAfter
        }
    }

    static func scheduler() -> FrameScheduler {
        FrameScheduler.testing(mediaTime: { 100 }) { _ in MotionClockIdleFakeLink() }
    }

    /// Runs the main actor until the clock has `count` parked waits.
    private static func park(_ clock: MotionClock, waits count: Int) async {
        for _ in 0..<100 where clock.idleWaiterCount < count { await Task.yield() }
    }

    @Test func anIdleClockAnswersAtOnce() async {
        let clock = MotionClock(scheduler: { Self.scheduler() })
        #expect(clock.isIdle)
        #expect(await clock.waitIdle())
        #expect(clock.idleWaiterCount == 0)
    }

    @Test func theFrameTheLastAnimatorRestsOnResumesTheWait() async {
        let scheduler = Self.scheduler()
        let clock = MotionClock(scheduler: { scheduler })
        let spring = Spring(restAfter: 2)
        clock.run(spring, trace: "test.spring")
        #expect(!clock.isIdle)
        let waiting = Task { await clock.waitIdle() }
        await Self.park(clock, waits: 1)
        #expect(clock.idleWaiterCount == 1)
        scheduler.frameDidFire(timestamp: 1.0, refreshInterval: 1.0 / 60)
        #expect(clock.idleWaiterCount == 1, "a frame that still moved resumed the wait")
        scheduler.frameDidFire(timestamp: 1.016, refreshInterval: 1.0 / 60)
        #expect(await waiting.value)
        #expect(clock.isIdle)
        #expect(clock.idleWaiterCount == 0)
    }

    @Test func stoppingTheLastAnimatorResumesTheWait() async {
        let scheduler = Self.scheduler()
        let clock = MotionClock(scheduler: { scheduler })
        let spring = Spring(restAfter: 100)
        clock.run(spring, trace: "test.spring")
        let waiting = Task { await clock.waitIdle() }
        await Self.park(clock, waits: 1)
        clock.stop(spring)
        #expect(await waiting.value)
        #expect(clock.idleWaiterCount == 0)
    }

    @Test func cancellingTheWaitReturnsFalse() async {
        let scheduler = Self.scheduler()
        let clock = MotionClock(scheduler: { scheduler })
        let spring = Spring(restAfter: 100)
        clock.run(spring, trace: "test.spring")
        let waiting = Task { await clock.waitIdle() }
        await Self.park(clock, waits: 1)
        #expect(clock.idleWaiterCount == 1, "the wait was not parked before the cancel")
        waiting.cancel()
        #expect(await waiting.value == false)
        for _ in 0..<100 where clock.idleWaiterCount > 0 { await Task.yield() }
        #expect(clock.idleWaiterCount == 0)
        clock.stop(spring)
    }

    @Test func existingClocksCreateNone() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let before = MotionClock.existing(in: [window])
        #expect(before.count == 1, "a window without a clock got one (only the app clock is expected)")
        let clock = MotionClock.forWindow(window)
        let after = MotionClock.existing(in: [window])
        #expect(after.count == 2)
        #expect(after.first === clock)
    }
}

@MainActor
private final class MotionClockIdleFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
