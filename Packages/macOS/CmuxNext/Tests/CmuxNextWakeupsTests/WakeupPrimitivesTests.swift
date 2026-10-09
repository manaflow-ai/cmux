import Foundation
import Synchronization
import Testing
@testable import CmuxNextWakeups

/// A clock whose sleeps end only when the test advances it.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private let state = Mutex<(now: Instant, sleepers: [UUID: Sleeper])>((Instant(offset: .zero), [:]))
    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready = state.withLock { state -> Bool in
                    if deadline <= state.now { return true }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for key in due.keys { state.sleepers[key] = nil }
            return Array(due.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Lets 10 000 turns pass (no condition): work that must NOT happen gets
/// every chance to run before the test checks it did not.
private func drainTurns() async {
    for _ in 0..<10_000 { await Task.yield() }
}

/// Waits up to 10 000 turns; a timeout records an Issue at the caller with the time waited.
private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: @escaping () -> Bool) async {
    let start = ContinuousClock.now
    for _ in 0..<10_000 where !condition() { await Task.yield() }
    if !condition() {
        Issue.record("waitUntil gave up after 10000 turns (\(ContinuousClock.now - start)): the condition at \(sourceLocation.fileName):\(sourceLocation.line) never held",
                     sourceLocation: sourceLocation)
    }
}

@Suite struct BackoffTests {
    @Test func growsExponentiallyAndCaps() {
        var backoff = Backoff(initial: .milliseconds(100), maximum: .seconds(1), jitter: 0, random: { 0.5 })
        let delays = (0..<6).map { _ in backoff.next() }
        #expect(delays == [.milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800), .seconds(1), .seconds(1)])
        backoff.reset()
        #expect(backoff.next() == .milliseconds(100))
    }

    @Test func jitterStaysWithinItsFraction() {
        var low = Backoff(initial: .seconds(1), maximum: .seconds(10), jitter: 0.2, random: { 0 })
        var high = Backoff(initial: .seconds(1), maximum: .seconds(10), jitter: 0.2, random: { 0.999_999 })
        #expect(abs(low.next().inSeconds - 0.8) < 0.001)
        #expect(abs(high.next().inSeconds - 1.2) < 0.001)
    }

    /// Settings outside the documented ranges used to trap in the initializer.
    @Test func outOfRangeSettingsAreCorrectedInsteadOfTrapping() {
        var backoff = Backoff(initial: .zero, maximum: .zero, multiplier: 0.5, jitter: 2, random: { 0.5 })
        #expect(backoff.initial == .milliseconds(100))
        #expect(backoff.maximum == .milliseconds(100))
        #expect(backoff.multiplier == 1)
        #expect(backoff.jitter == 1)
        #expect(backoff.next() == .milliseconds(100))
        let nanJitter = Backoff(jitter: .nan)
        #expect(nanJitter.jitter == 0)
    }
}

@Suite struct DemandTimerTests {
    @Test func firesOnceAfterItsDelay() async {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let timer = DemandTimer(owner: "test", clock: clock, ledger: ledger)
        let fired = Mutex(0)
        timer.schedule(after: .seconds(1)) { fired.withLock { $0 += 1 } }
        await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .milliseconds(999))
        #expect(fired.withLock { $0 } == 0)
        clock.advance(by: .milliseconds(1))
        await waitUntil { fired.withLock { $0 } == 1 }
        clock.advance(by: .seconds(10))
        await drainTurns()
        #expect(fired.withLock { $0 } == 1)
        #expect(!timer.isScheduled)
        #expect(ledger.snapshot().first?.count == 1)
    }

    @Test func resetReplacesThePendingDeadline() async {
        let clock = ManualClock()
        let timer = DemandTimer(owner: "test", clock: clock, ledger: WakeupLedger())
        let fired = Mutex<[Int]>([])
        timer.schedule(after: .seconds(1)) { fired.withLock { $0.append(1) } }
        await waitUntil { clock.sleeperCount == 1 }
        timer.schedule(after: .seconds(1)) { fired.withLock { $0.append(2) } }
        await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(1))
        await waitUntil { !fired.withLock { $0.isEmpty } }
        #expect(fired.withLock { $0 } == [2])
    }

    @Test func cancelDropsTheDeadline() async {
        let clock = ManualClock()
        let timer = DemandTimer(owner: "test", clock: clock, ledger: WakeupLedger())
        let fired = Mutex(false)
        timer.schedule(after: .seconds(1)) { fired.withLock { $0 = true } }
        await waitUntil { clock.sleeperCount == 1 }
        timer.cancel()
        await waitUntil { clock.sleeperCount == 0 }
        clock.advance(by: .seconds(2))
        await drainTurns()
        #expect(!fired.withLock { $0 })
    }
}

@Suite struct WakeupLedgerTests {
    @Test func ratesCoverTheLastCompleteSeconds() {
        let now = Mutex<UInt64>(100_000_000_000)
        let ledger = WakeupLedger(uptime: { now.withLock { $0 } })
        for _ in 0..<50 { ledger.record("pump", reason: "timer") }
        now.withLock { $0 += 1_000_000_000 }
        let entry = ledger.snapshot().first
        #expect(entry?.count == 50)
        #expect(entry?.perSecond == 5)
        // Idle: the rate decays to zero once the window passes.
        now.withLock { $0 += 30_000_000_000 }
        #expect(ledger.snapshot().first?.perSecond == 0)
        #expect(ledger.snapshot().first?.count == 50)
    }

    @Test func ownersAndReasonsAreSeparate() {
        let ledger = WakeupLedger()
        ledger.record("a", reason: "x")
        ledger.record("a", reason: "y")
        ledger.record("b")
        #expect(ledger.snapshot().count == 3)
        #expect(ledger.activitySequence == 3)
    }
}

@Suite struct UpdateCycleTests {
    @Test func reportsReentry() {
        let ledger = WakeupLedger()
        let detector = UpdateCycleDetector(owner: "store", ledger: ledger)
        detector.run { detector.run {} }
        #expect(detector.reentryCount == 1)
        detector.run {}
        #expect(detector.reentryCount == 1)
    }

    @Test func sameValueDoesNotAssign() {
        final class Box { var value = 1; var sets = 0 }
        let box = Box()
        #expect(!assignIfChanged(box, \.value, 1))
        #expect(assignIfChanged(box, \.value, 2))
        #expect(box.value == 2)
    }
}

@Suite struct ProcessUsageTests {
    @Test func samplesThisProcess() throws {
        let usage = try #require(ProcessUsage.sample(getpid()))
        #expect(usage.cpuNanos > 0)
        #expect(usage.path.hasSuffix(usage.name))
        #expect(usage.parent > 0)
        #expect(!ProcessUsage.arguments(of: getpid()).isEmpty)
    }
}
