import CmuxNextCompat
import Foundation
import Testing

/// ``PlatformEvents`` is one thread's event-driven wait on both kernels (p15-oracle-126): a kqueue on Darwin,
/// epoll with a timerfd and an eventfd on Linux. The timer and the user event each end a wait, a timeout ends
/// it empty, and nothing fires twice.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlatformEventsTests {
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    @Test func aWakeBeforeTheWaitEndsItOnceAsAUserEvent() {
        let events = PlatformEvents()
        #expect(events.isAvailable)
        events.wake()
        events.wake()
        #expect(events.wait(nanos: nil) == .user, "two wakes before one wait end that wait")
        #expect(events.wait(nanos: 2_000_000) == [], "and only that one")
    }

    @Test func theArmedTimerFiresOnceAndNotBeforeItsDeadline() {
        let events = PlatformEvents()
        let start = Self.now()
        events.arm(afterNanos: 5_000_000)
        #expect(events.wait(nanos: nil) == .timer)
        #expect(Self.now() - start >= 4_000_000, "the timer fired at its deadline, not before")
        #expect(events.wait(nanos: 10_000_000) == [], "the timer is one-shot")
    }

    @Test func disarmDropsAPendingTimerAndOneThatFiredUnseen() {
        let events = PlatformEvents()
        events.arm(afterNanos: 3_000_000)
        events.disarm()
        #expect(events.wait(nanos: 10_000_000) == [], "a pending timer is gone")
        events.arm(afterNanos: 1)
        PlatformEvents().wait(nanos: 5_000_000) // let the timer fire with no wait to see it
        events.disarm()
        #expect(events.wait(nanos: 5_000_000) == [], "a fired, unread timer is gone too")
    }

    @Test func aTimeoutEndsTheWaitEmptyAfterItsLength() {
        let events = PlatformEvents()
        let start = Self.now()
        #expect(events.wait(nanos: 3_000_000) == [])
        #expect(Self.now() - start >= 2_500_000, "the wait lasts its timeout")
    }

    @Test func aWakeFromAnotherThreadEndsAnUnboundedWait() {
        let events = PlatformEvents()
        let sawUser = PlatformEvents()
        // A thread of its own parks in the wait, as the watchdog's does; it reports through a second queue.
        Thread { if events.wait(nanos: nil) == .user { sawUser.wake() } }.start()
        PlatformEvents().wait(nanos: 5_000_000) // let the waiter park first; a wake before its wait works too
        events.wake()
        #expect(sawUser.wait(nanos: 10_000_000_000) == .user, "the parked thread woke with a user event")
    }
}
