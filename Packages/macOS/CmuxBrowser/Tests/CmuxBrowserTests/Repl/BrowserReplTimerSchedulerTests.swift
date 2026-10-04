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

/// A clock whose instants count how often they are compared, so a test can
/// measure the scheduler's work in comparisons instead of wall time. Its
/// time never moves; a sleep lasts until it is cancelled.
struct BrowserReplComparisonCountingClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool {
            BrowserReplComparisonCountingClock.comparisons.increment()
            return lhs.offset < rhs.offset
        }
    }

    /// Comparisons of this clock's instants; only one test uses the clock.
    static let comparisons = BrowserReplResponseCounter()

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await Task.sleep(for: .seconds(86_400))
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

    /// Each schedule and cancel finds the earliest deadline again; scanning
    /// every timer for it makes 10,000 of each about 10^8 comparisons.
    @Test("10,000 schedules and cancels take O(n log n) deadline comparisons, not O(n^2)")
    func scheduleAndCancelScale() {
        let clock = BrowserReplComparisonCountingClock()
        let scheduler = BrowserReplTimerScheduler(clock: clock) { _ in }
        defer { scheduler.invalidate() }
        let count = 10_000
        // Deadlines in a scrambled order (a fixed linear congruential sequence).
        var seed: UInt64 = 12_345
        let before = BrowserReplComparisonCountingClock.comparisons.count
        for id in 0..<count {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            #expect(scheduler.schedule(id: id, after: .milliseconds(Int64(1 + seed >> 44)), repeating: false))
        }
        for id in 0..<count { scheduler.cancel(id: id) }
        let comparisons = BrowserReplComparisonCountingClock.comparisons.count - before

        #expect(scheduler.count == 0)
        // n log2 n is about 133,000 per pass; a scan per call is about 10^8.
        #expect(comparisons < 1_500_000, "\(comparisons) comparisons for \(count) schedules and \(count) cancels")
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
