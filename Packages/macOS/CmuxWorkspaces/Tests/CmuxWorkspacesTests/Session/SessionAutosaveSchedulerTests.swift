import Foundation
import Testing
@testable import CmuxWorkspaces

/// In-memory host for ``SessionAutosaveScheduler``: records every
/// ``performScheduledAutosave(source:)`` call and lets a test flip the
/// terminating flag the scheduler reads on each tick.
@MainActor
private final class FakeAutosaveHost: SessionAutosaveScheduling {
    var isTerminatingApp = false
    private(set) var savedSources: [String] = []
    /// When set, each save awaits this continuation before returning, so a test
    /// can observe the in-flight latch window.
    var pauseSave = false
    private var pendingSaveResume: CheckedContinuation<Void, Never>?

    func performScheduledAutosave(source: String) async {
        savedSources.append(source)
        if pauseSave {
            await withCheckedContinuation { continuation in
                pendingSaveResume = continuation
            }
        }
    }

    func resumePausedSave() {
        pendingSaveResume?.resume()
        pendingSaveResume = nil
    }

    var saveCount: Int { savedSources.count }
}

/// A virtual-time clock: `sleep(for:)` suspends until the test ``advance(by:)``s
/// virtual time past the sleep's deadline. Waiters fire in deadline order, so
/// the 8 s interval sleep and the sub-second deferred-retry sleep are
/// distinguished by their deadlines (a FIFO release could not tell them apart).
/// Cancellation abandons the waiter, matching `ContinuousClock`.
///
/// `Clock` requires a `nonisolated now`, so this is a plain `Sendable` class
/// guarding its mutable state with a lock rather than a `@MainActor` type. The
/// test driver only touches it from the main actor.
private final class ManualReleaseClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    // Justification: a test-only virtual clock. All state is guarded by `lock`;
    // `@unchecked Sendable` is required because `Clock.now`/`sleep` are
    // nonisolated and the state is mutated from both the sleeping tasks and the
    // test driver.
    private let lock = NSLock()
    private var virtualNow: Duration = .zero
    private var waiters: [(deadline: Duration, resume: () -> Void)] = []

    var minimumResolution: Duration { .zero }

    var now: Instant {
        lock.lock(); defer { lock.unlock() }
        return Instant(offset: virtualNow)
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if deadline.offset <= virtualNow {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((deadline.offset, { continuation.resume() }))
                    lock.unlock()
                }
            }
        } onCancel: {
            // The registered waiter simply never resumes, matching a cancelled
            // real sleep whose continuation is abandoned.
        }
    }

    /// Advances virtual time, firing every waiter whose deadline is now reached,
    /// in deadline order.
    func advance(by duration: Duration) {
        lock.lock()
        virtualNow += duration
        var fired: [() -> Void] = []
        while let index = waiters.firstIndex(where: { $0.deadline <= virtualNow }) {
            fired.append(waiters.remove(at: index).resume)
        }
        lock.unlock()
        fired.forEach { $0() }
    }

    var pendingSleepCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }
}

@MainActor
@Suite struct SessionAutosaveSchedulerTests {
    /// Yields enough times for the scheduler's child tasks to make progress.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// Builds a scheduler whose typing-quiet uptime tracks the same virtual
    /// clock (in seconds), so a `clock.advance(by:)` moves both the sleep
    /// deadlines and the typing-quiet "now" together, exactly as the legacy
    /// monotonic `systemUptime` did.
    private func makeScheduler(
        host: FakeAutosaveHost,
        clock: ManualReleaseClock,
        typingQuietPeriod: TimeInterval = 0.65
    ) -> SessionAutosaveScheduler {
        let scheduler = SessionAutosaveScheduler(
            interval: .seconds(8),
            typingQuietPeriod: typingQuietPeriod,
            clock: clock,
            uptime: {
                let components = clock.now.offset.components
                return TimeInterval(components.seconds)
                    + TimeInterval(components.attoseconds) / 1e18
            }
        )
        scheduler.attach(host: host)
        return scheduler
    }

    @Test func timerTickPerformsAutosaveAtInterval() async {
        let host = FakeAutosaveHost()
        let clock = ManualReleaseClock()
        let scheduler = makeScheduler(host: host, clock: clock)
        scheduler.start()
        await settle()

        // One interval elapses -> one autosave from the "timer" source.
        clock.advance(by: .seconds(8))
        await settle()
        #expect(host.savedSources == ["timer"])

        // A second interval elapses -> a second autosave.
        clock.advance(by: .seconds(8))
        await settle()
        #expect(host.savedSources == ["timer", "timer"])
        scheduler.stop()
    }

    @Test func typingWithinQuietPeriodDefersThenRetries() async {
        let host = FakeAutosaveHost()
        let clock = ManualReleaseClock()
        let scheduler = makeScheduler(host: host, clock: clock)
        scheduler.start()
        await settle()

        // Keypress at t=8 - epsilon: advance to just before the interval, type,
        // then let the interval fire. The tick lands inside the 0.65 s window.
        clock.advance(by: .milliseconds(7600)) // t=7.6
        scheduler.recordTypingActivity()
        clock.advance(by: .milliseconds(400)) // t=8.0: interval fires, 0.4 s since typing
        await settle()
        // Inside the quiet window -> deferred, not saved.
        #expect(host.saveCount == 0)
        #expect(clock.pendingSleepCount >= 1)

        // Remaining quiet period (0.25 s) elapses -> the deferred retry saves.
        clock.advance(by: .milliseconds(250)) // t=8.25
        await settle()
        #expect(host.savedSources == ["typingQuietRetry"])
        scheduler.stop()
    }

    @Test func typingQuietBoundaryIsExclusiveAtExactly065() async {
        let host = FakeAutosaveHost()
        let clock = ManualReleaseClock()
        let scheduler = makeScheduler(host: host, clock: clock)
        scheduler.start()
        await settle()

        // Keypress at t=7.35; the interval fires at t=8.0, i.e. exactly 0.65 s
        // later -> elapsed == period, which is NOT < period, so it saves
        // (legacy `guard elapsed < period else { return nil }`).
        clock.advance(by: .milliseconds(7350)) // t=7.35
        scheduler.recordTypingActivity()
        clock.advance(by: .milliseconds(650)) // t=8.0: interval fires, elapsed == 0.65
        await settle()
        #expect(host.savedSources == ["timer"])
        scheduler.stop()
    }

    @Test func tickInFlightDropsOverlappingTick() async {
        let host = FakeAutosaveHost()
        host.pauseSave = true
        let clock = ManualReleaseClock()
        let scheduler = makeScheduler(host: host, clock: clock)
        scheduler.start()
        await settle()

        // First tick starts a save that is paused (latch held).
        clock.advance(by: .seconds(8))
        await settle()
        #expect(host.saveCount == 1)

        // Second interval fires while the first save is still in flight -> dropped.
        clock.advance(by: .seconds(8))
        await settle()
        #expect(host.saveCount == 1)

        // Releasing the paused save clears the latch; a later tick saves again.
        host.pauseSave = false
        host.resumePausedSave()
        await settle()
        clock.advance(by: .seconds(8))
        await settle()
        #expect(host.saveCount == 2)
        scheduler.stop()
    }

    @Test func terminatingAppSuppressesTick() async {
        let host = FakeAutosaveHost()
        host.isTerminatingApp = true
        let clock = ManualReleaseClock()
        let scheduler = makeScheduler(host: host, clock: clock)
        scheduler.start()
        await settle()

        clock.advance(by: .seconds(8))
        await settle()
        #expect(host.saveCount == 0)
        scheduler.stop()
    }

    @Test func suspendedAutosaveNeverArmsTimer() async {
        let host = FakeAutosaveHost()
        let clock = ManualReleaseClock()
        let scheduler = SessionAutosaveScheduler(
            interval: .seconds(8),
            clock: clock,
            uptime: { 0 },
            isAutosaveSuspended: { true }
        )
        scheduler.attach(host: host)
        scheduler.start()
        await settle()

        // No sleep was ever registered: the timer loop never started.
        #expect(clock.pendingSleepCount == 0)
        #expect(host.saveCount == 0)
    }

    @Test func stopBeforeRetryFiresCancelsTheRetry() async {
        let host = FakeAutosaveHost()
        let clock = ManualReleaseClock()
        let scheduler = makeScheduler(host: host, clock: clock)
        scheduler.start()
        await settle()

        clock.advance(by: .milliseconds(7700)) // t=7.7
        scheduler.recordTypingActivity()
        clock.advance(by: .milliseconds(300)) // t=8.0: interval fires, 0.3 s since typing
        await settle()
        #expect(host.saveCount == 0) // deferred

        // Stop bumps the generation; the still-pending retry sleep, once its
        // deadline is reached, is a no-op (cancellation via guard).
        scheduler.stop()
        clock.advance(by: .seconds(1))
        await settle()
        #expect(host.saveCount == 0)
    }
}
