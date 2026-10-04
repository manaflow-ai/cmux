import Foundation
import Testing

@testable import CmuxBrowser

/// A clock that only moves when a test advances it.
final class BrowserReplManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = lock.withLock {
                    if Task.isCancelled || deadline <= current { return true }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if resumeNow {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for key in ready.keys { sleepers.removeValue(forKey: key) }
            return Array(ready.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Collects fired timer ids and lets a test await the next ones.
final class FiredTimers: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<[Int], Never>)] = []

    func record(_ id: Int) {
        let ready: [CheckedContinuation<[Int], Never>]
        let snapshot: [Int]
        (ready, snapshot) = lock.withLock {
            ids.append(id)
            let satisfied = waiters.filter { $0.count <= ids.count }
            waiters.removeAll { $0.count <= ids.count }
            return (satisfied.map(\.continuation), ids)
        }
        for continuation in ready { continuation.resume(returning: snapshot) }
    }

    func wait(forCount count: Int) async -> [Int] {
        await withCheckedContinuation { continuation in
            let snapshot: [Int]? = lock.withLock {
                if ids.count >= count { return ids }
                waiters.append((count, continuation))
                return nil
            }
            if let snapshot { continuation.resume(returning: snapshot) }
        }
    }
}

@Suite("Browser REPL timer scheduler")
struct BrowserReplTimerSchedulerTests {
    @Test("Timers fire in deadline order, ties in scheduling order")
    func deadlineOrder() async {
        let clock = BrowserReplManualClock()
        let fired = FiredTimers()
        let scheduler = BrowserReplTimerScheduler(clock: clock) { fired.record($0) }

        scheduler.schedule(id: 1, after: .milliseconds(10), repeating: false)
        scheduler.schedule(id: 2, after: .milliseconds(5), repeating: false)
        scheduler.schedule(id: 3, after: .milliseconds(10), repeating: false)
        clock.advance(by: .milliseconds(10))

        #expect(await fired.wait(forCount: 3) == [2, 1, 3])
        #expect(scheduler.count == 0)
    }

    @Test("A cancelled timer never fires")
    func cancelledTimerDoesNotFire() async {
        let clock = BrowserReplManualClock()
        let fired = FiredTimers()
        let scheduler = BrowserReplTimerScheduler(clock: clock) { fired.record($0) }

        scheduler.schedule(id: 1, after: .milliseconds(10), repeating: false)
        scheduler.schedule(id: 2, after: .milliseconds(20), repeating: false)
        scheduler.cancel(id: 1)
        clock.advance(by: .milliseconds(30))

        #expect(await fired.wait(forCount: 1) == [2])
        #expect(!scheduler.isScheduled(id: 1))
    }

    @Test("Scheduling an earlier timer preempts the sleeping one")
    func earlierTimerPreempts() async {
        let clock = BrowserReplManualClock()
        let fired = FiredTimers()
        let scheduler = BrowserReplTimerScheduler(clock: clock) { fired.record($0) }

        scheduler.schedule(id: 1, after: .seconds(60), repeating: false)
        scheduler.schedule(id: 2, after: .milliseconds(1), repeating: false)
        clock.advance(by: .milliseconds(1))

        #expect(await fired.wait(forCount: 1) == [2])
        #expect(scheduler.isScheduled(id: 1))
    }

    @Test("An interval re-arms after each delivered fire until cancelled")
    func intervalRepeatsUntilCancelled() async {
        let clock = BrowserReplManualClock()
        let fired = FiredTimers()
        let scheduler = BrowserReplTimerScheduler(clock: clock) { fired.record($0) }

        scheduler.schedule(id: 7, after: .milliseconds(10), repeating: true)
        clock.advance(by: .milliseconds(10))
        #expect(await fired.wait(forCount: 1) == [7])
        scheduler.delivered(id: 7)
        clock.advance(by: .milliseconds(10))
        #expect(await fired.wait(forCount: 2) == [7, 7])

        scheduler.cancel(id: 7)
        scheduler.schedule(id: 8, after: .milliseconds(15), repeating: false)
        clock.advance(by: .milliseconds(20))
        #expect(await fired.wait(forCount: 3) == [7, 7, 8])
    }

    @Test("An interval whose last fire has not run yet does not fire again")
    func overdueIntervalTicksCoalesce() async {
        let clock = BrowserReplManualClock()
        let fired = FiredTimers()
        let scheduler = BrowserReplTimerScheduler(clock: clock) { fired.record($0) }

        scheduler.schedule(id: 7, after: .milliseconds(10), repeating: true)
        clock.advance(by: .milliseconds(10))
        #expect(await fired.wait(forCount: 1) == [7])
        // The JS thread is busy: interval 7's fire is still queued there.
        clock.advance(by: .milliseconds(10))
        clock.advance(by: .milliseconds(10))
        scheduler.schedule(id: 8, after: .milliseconds(1), repeating: false)
        clock.advance(by: .milliseconds(1))

        #expect(await fired.wait(forCount: 2) == [7, 8])
    }

    @Test("A fired timer counts toward the cap until its callback ran")
    func firedTimersCountUntilDelivered() async {
        let clock = BrowserReplManualClock()
        let fired = FiredTimers()
        let scheduler = BrowserReplTimerScheduler(clock: clock, maximumTimers: 2) { fired.record($0) }

        #expect(scheduler.schedule(id: 1, after: .milliseconds(1), repeating: false))
        #expect(scheduler.schedule(id: 2, after: .milliseconds(1), repeating: false))
        #expect(!scheduler.schedule(id: 3, after: .milliseconds(1), repeating: false))
        clock.advance(by: .milliseconds(1))
        #expect(await fired.wait(forCount: 2) == [1, 2])

        // Both fired, but the busy JS thread has not run their callbacks.
        #expect(scheduler.count == 0)
        #expect(!scheduler.schedule(id: 3, after: .milliseconds(1), repeating: false))
        scheduler.delivered(id: 1)
        #expect(scheduler.schedule(id: 3, after: .milliseconds(1), repeating: false))
        #expect(!scheduler.schedule(id: 4, after: .milliseconds(1), repeating: false))
    }

    @Test("Invalidation drops pending timers and refuses new ones")
    func invalidation() async {
        let clock = BrowserReplManualClock()
        let fired = FiredTimers()
        let scheduler = BrowserReplTimerScheduler(clock: clock) { fired.record($0) }

        scheduler.schedule(id: 1, after: .milliseconds(5), repeating: false)
        scheduler.invalidate()
        scheduler.schedule(id: 2, after: .milliseconds(5), repeating: false)
        #expect(scheduler.count == 0)
    }
}
